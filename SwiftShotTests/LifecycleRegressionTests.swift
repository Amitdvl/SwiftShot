import AppKit
import XCTest
@testable import SwiftShot

@MainActor
final class LifecycleRegressionTests: XCTestCase {
    func testCombineCanceledDuringRecoveryAdmissionDoesNotReadHistorySources() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        let current = CaptureDocument(image: fixture.image)
        current.isPrivate = true
        fixture.app.lastDocument = current
        let gate = LifecycleDiskGate()
        defer { gate.release() }
        let hold = Task.detached { await fixture.coordinator.holdForLifecycleTest(gate) }
        try await wait { gate.started }

        // Missing IDs are a read sentinel: a superseded request must cancel before
        // looking them up, not surface an unrelated missing-history error.
        let combining = Task { try await fixture.app.combineHistory([UUID(), UUID()], axis: .vertical) }
        try await wait { fixture.app.phase == .freezing }
        await fixture.app.reopenLastCapture()
        XCTAssertTrue(fixture.presenter.activeDocument === current)
        gate.release()
        await hold.value

        do {
            try await combining.value
            XCTFail("A combine superseded during recovery admission must be canceled")
        } catch {
            XCTAssertTrue(error is CancellationError,
                "Stale combine read history after navigation instead of canceling: \(error)")
        }
        XCTAssertTrue(fixture.presenter.activeDocument === current)
        XCTAssertEqual(fixture.app.phase, .editing)
        _ = await fixture.app.prepareToQuit()
    }

    func testPrivateRecaptureKeepsSubsequentRecapturesPrivateAfterPreferenceTurnsOff() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        XCTAssertEqual(fixture.app.lastRegion?.isPrivate, false)
        fixture.app.appSettings.privateCapture = true

        let firstSucceeded = await fixture.app.captureLastRegion()
        XCTAssertTrue(firstSucceeded)
        let first = try XCTUnwrap(fixture.app.lastDocument)
        XCTAssertTrue(first.isPrivate)
        XCTAssertEqual(first.sourceRegion?.isPrivate, true,
            "The recaptured image's immutable source reference must carry its private classification")
        XCTAssertEqual(fixture.app.lastRegion?.isPrivate, true,
            "Future recaptures must inherit the last capture's privacy, not the original public reference")
        XCTAssertNil(fixture.app.appSettings.lastRegion)
        let firstSettings = try JSONDecoder().decode(AppSettings.self,
            from: XCTUnwrap(fixture.defaults.data(forKey: "com.swiftshot.settings")))
        XCTAssertNil(firstSettings.lastRegion, "Private last-region geometry must stay out of persisted settings")

        fixture.app.appSettings.privateCapture = false
        let secondSucceeded = await fixture.app.captureLastRegion()
        XCTAssertTrue(secondSucceeded)
        let second = try XCTUnwrap(fixture.app.lastDocument)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertTrue(second.isPrivate, "A later preference change must not make recapture of a private region public")
        XCTAssertEqual(second.sourceRegion?.isPrivate, true)
        XCTAssertEqual(fixture.app.lastRegion?.isPrivate, true)
        XCTAssertNil(fixture.app.appSettings.lastRegion)
        let secondSettings = try JSONDecoder().decode(AppSettings.self,
            from: XCTUnwrap(fixture.defaults.data(forKey: "com.swiftshot.settings")))
        XCTAssertNil(secondSettings.lastRegion)
        let preserved = await fixture.app.preserve(second)
        XCTAssertTrue(preserved)
        let records = try await fixture.store.records()
        XCTAssertTrue(records.isEmpty, "Neither private recapture may create a recovery original")
        _ = await fixture.app.prepareToQuit()
    }

    func testPrivateRecaptureFreezesPrivacyBeforeAcquisitionSuspends() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        fixture.app.appSettings.privateCapture = true
        let gate = LifecycleAsyncGate()
        fixture.capture.gate = gate
        let work = Task { await fixture.app.captureLastRegion() }
        try await wait { gate.started }
        fixture.app.appSettings.privateCapture = false
        gate.release()
        let succeeded = await work.value
        XCTAssertTrue(succeeded)
        let document = try XCTUnwrap(fixture.app.lastDocument)
        XCTAssertTrue(document.isPrivate, "Turning off a later preference must not publish a private in-flight capture")
        _ = await fixture.app.preserve(document)
        let records = try await fixture.store.records()
        XCTAssertTrue(records.isEmpty)
        _ = await fixture.app.prepareToQuit()
    }

    func testPrivateCombineFreezesPrivacyBeforeHistoryReadsSuspend() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        let first = CaptureDocument(image: fixture.image), second = CaptureDocument(image: fixture.image)
        for document in [first, second] {
            try await fixture.store.persist(id: document.id, image: document.image, edits: document.edits, revision: document.revision, savedURL: nil)
        }
        let gate = LifecycleDiskGate()
        defer { gate.release() }
        let hold = Task.detached { await fixture.store.holdForLifecycleTest(gate) }
        try await wait { gate.started }
        fixture.app.appSettings.privateCapture = true
        let combining = Task { try await fixture.app.combineHistory([first.id, second.id], axis: .vertical) }
        try await wait { fixture.app.phase == .freezing }
        fixture.app.appSettings.privateCapture = false
        gate.release(); await hold.value
        try await combining.value
        let result = try XCTUnwrap(fixture.app.lastDocument)
        XCTAssertTrue(result.isPrivate)
        _ = await fixture.app.preserve(result)
        let ids = Set(try await fixture.store.records().map(\.id))
        XCTAssertEqual(ids, Set([first.id, second.id]), "Only the two pre-existing originals belong on disk")
        _ = await fixture.app.prepareToQuit()
    }

    func testOldNativeDragCompletionCannotCloseNewCapture() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        await fixture.app.capture(mode: .region, privateCapture: true)
        fixture.presenter.select(CaptureDocument(image: fixture.image))
        let oldEnd = fixture.presenter.actions.dragEnded
        await fixture.app.capture(mode: .region, privateCapture: true)
        let current = CaptureDocument(image: fixture.image)
        fixture.presenter.select(current)
        oldEnd()
        XCTAssertTrue(fixture.presenter.activeDocument === current)
        XCTAssertEqual(fixture.app.phase, .editing)
        _ = await fixture.app.prepareToQuit()
    }

    func testPinCompletionCannotCloseAnEditedRevision() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        await fixture.app.capture(mode: .region, privateCapture: true)
        let document = CaptureDocument(image: fixture.image)
        fixture.presenter.select(document)
        let gate = LifecycleAsyncGate()
        fixture.floating.gate = gate
        let pin = Task { await fixture.app.pin(document) }
        try await wait { gate.started }
        document.change { $0.style.padding = 91 }
        fixture.presenter.select(document)
        gate.release(); await pin.value
        XCTAssertTrue(fixture.presenter.activeDocument === document)
        XCTAssertEqual(document.edits.style.padding, 91)
        _ = await fixture.app.prepareToQuit()
    }

    func testPinCompletionCannotCloseReopenedSameDocument() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        await fixture.app.capture(mode: .region, privateCapture: true)
        let document = CaptureDocument(image: fixture.image)
        fixture.presenter.select(document)
        let gate = LifecycleAsyncGate()
        fixture.floating.gate = gate
        let pin = Task { await fixture.app.pin(document) }
        try await wait { gate.started }
        await fixture.app.reopenLastCapture()
        gate.release(); await pin.value
        XCTAssertTrue(fixture.presenter.activeDocument === document)
        _ = await fixture.app.prepareToQuit()
    }

    func testFailedCaptureAdmissionRestoresWorkingEditorCallbacks() async throws {
        let fixture = try LifecycleFixture(maximumPendingBytes: 1)
        defer { fixture.cleanUp() }
        await fixture.app.capture(mode: .region)
        let document = CaptureDocument(image: fixture.image)
        fixture.presenter.select(document)
        await fixture.app.capture(mode: .region)
        XCTAssertTrue(fixture.presenter.activeDocument === document)
        document.change { $0.style.padding = 93 }
        fixture.presenter.select(document)
        XCTAssertEqual(fixture.app.appSettings.style.padding, 93, "Failed navigation left the old callback bound to an invalid token")
        document.isPrivate = true
        _ = await fixture.app.prepareToQuit()
    }

    func testEditingOlderPinCannotReplaceOriginalWithoutRecoveryOwnership() async throws {
        let fixture = try LifecycleFixture(maximumPendingBytes: 1)
        defer { fixture.cleanUp() }
        await fixture.app.capture(mode: .region)
        let current = CaptureDocument(image: fixture.image)
        fixture.presenter.select(current)
        let oldPin = CaptureDocument(image: fixture.image)
        oldPin.isPrivate = true
        await fixture.app.pin(oldPin)
        let edit = try XCTUnwrap(fixture.floating.onEdit)
        edit(oldPin)
        // Give the real async ownership transfer a chance to complete/reject.
        try await wait { fixture.presenter.reopenCount > 0 }
        XCTAssertTrue(fixture.app.lastDocument === current, "The only owner of an undurable original was replaced")
        XCTAssertTrue(fixture.presenter.activeDocument === current)
        current.isPrivate = true
        _ = await fixture.app.prepareToQuit()
    }

    private func wait(_ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw NSError(domain: "LifecycleFixtureTimeout", code: 1)
    }
}

@MainActor
private struct LifecycleFixture {
    let root: URL
    let image: CGImage
    let store: RecoveryStore
    let coordinator: RecoveryCoordinator
    let capture: LifecycleCapture
    let presenter = LifecyclePresenter()
    let floating = LifecycleFloating()
    let app: AppState
    let suiteName = "SwiftShotLifecycle.\(UUID())"
    let defaults: UserDefaults
    init(maximumPendingBytes: Int = 512 * 1024 * 1024) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftShotLifecycle-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 40, bitsPerComponent: 8, bytesPerRow: 256,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 64, height: 40))
        image = try XCTUnwrap(context.makeImage())
        store = RecoveryStore(root: root.appendingPathComponent("recovery"))
        coordinator = RecoveryCoordinator(store: store, maximumPendingBytes: maximumPendingBytes)
        capture = LifecycleCapture(image: image)
        var settings = AppSettings.default
        settings.lastRegion = CaptureRegionReference(screen: capture.screen, crop: CGRect(x: 0, y: 0, width: 64, height: 40), isPrivate: false)
        try defaults.set(JSONEncoder().encode(settings), forKey: "com.swiftshot.settings")
        app = AppState(defaults: defaults, recovery: store,
            backgrounds: BackgroundLibrary(rootURL: root.appendingPathComponent("backgrounds")), presentsUI: false,
            captureService: capture, overlay: presenter,
            recoveryCoordinator: coordinator, floatingCaptures: floating)
    }
    func cleanUp() { defaults.removePersistentDomain(forName: suiteName); try? FileManager.default.removeItem(at: root) }
}

@MainActor
private final class LifecycleAsyncGate {
    private(set) var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func hold() async { started = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor
private final class LifecycleCapture: ScreenCaptureProviding {
    let image: CGImage
    var gate: LifecycleAsyncGate?
    var screen: FrozenScreen { FrozenScreen(id: 7, frame: CGRect(x: 10, y: 20, width: 64, height: 40), image: image, windows: []) }
    init(image: CGImage) { self.image = image }
    func freeze(mode: CaptureMode) async throws -> [FrozenScreen] { [screen] }
    func currentDisplayFrame(id: UInt32) -> CGRect? { id == 7 ? screen.frame : nil }
    func captureRegion(displayID: UInt32, rect: CGRect) async throws -> CGImage { await gate?.hold(); return image }
}

@MainActor
private final class LifecycleFloating: FloatingCapturePresenting {
    var gate: LifecycleAsyncGate?
    var onEdit: ((CaptureDocument) -> Void)?
    func showRecent(document: CaptureDocument, backgroundURL: URL?, renderedImage: CGImage?,
                    title: String, onCopy: @escaping (CaptureDocument) -> Void, onEdit: @escaping (CaptureDocument) -> Void, onSave: @escaping (CaptureDocument) -> Void,
                    onPin: @escaping (CaptureDocument) -> Void) async throws { self.onEdit = onEdit }
    func pin(document: CaptureDocument, backgroundURL: URL?,
             onCopy: @escaping (CaptureDocument) -> Void, onEdit: @escaping (CaptureDocument) -> Void, onSave: @escaping (CaptureDocument) -> Void) async throws {
        self.onEdit = onEdit; await gate?.hold()
    }
    func setCaptureHidden(_ hidden: Bool) {}
    func closeAll() {}
    func handleMemoryPressure() {}
}

@MainActor
private final class LifecyclePresenter: CapturePresenting {
    var activeDocument: CaptureDocument?
    var reopenCount = 0
    var actions = CaptureActions()
    private var onDocument: ((CaptureDocument) -> Void)?
    func configure(actions: CaptureActions) { self.actions = actions }
    func select(_ document: CaptureDocument) { activeDocument = document; onDocument?(document) }
    func present(screens: [FrozenScreen], mode: CaptureMode, style: CaptureStyle, library: BackgroundLibrary,
                 onDocument: @escaping (CaptureDocument) -> Void, onCopy: @escaping (CaptureDocument) -> Void,
                 onSave: @escaping (CaptureDocument) -> Void, onOCR: @escaping (CaptureDocument) -> Void,
                 onCancel: @escaping () -> Void, onDiscard: @escaping (CaptureDocument) -> Void) { self.onDocument = onDocument }
    func reopen(document: CaptureDocument, library: BackgroundLibrary, onCopy: @escaping (CaptureDocument) -> Void,
                onSave: @escaping (CaptureDocument) -> Void, onCancel: @escaping () -> Void,
                onDocument: @escaping (CaptureDocument) -> Void, onDiscard: @escaping (CaptureDocument) -> Void) {
        activeDocument = document; self.onDocument = onDocument; reopenCount += 1
    }
    func dismiss() { activeDocument = nil }
    func showStatus(_ message: String, isError: Bool) {}
}

private final class LifecycleDiskGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var didStart = false
    private var released = false
    var started: Bool { condition.lock(); defer { condition.unlock() }; return didStart }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
    func hold() {
        condition.lock(); defer { condition.unlock() }
        didStart = true
        let deadline = Date().addingTimeInterval(5)
        while !released { if !condition.wait(until: deadline) { return } }
    }
}

extension RecoveryStore {
    fileprivate func holdForLifecycleTest(_ gate: LifecycleDiskGate) { gate.hold() }
}

extension RecoveryCoordinator {
    fileprivate func holdForLifecycleTest(_ gate: LifecycleDiskGate) { gate.hold() }
}
