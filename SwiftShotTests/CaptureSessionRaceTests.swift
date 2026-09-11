import XCTest
import AppKit
@testable import SwiftShot

@MainActor
final class CaptureSessionRaceTests: XCTestCase {
    func testInFlightFreezeCannotReplaceReopenedDocument() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let gate = RaceGate()
        let capture = RaceCaptureService(image: fixture.image, gate: gate)
        let presenter = RacePresenter()
        let app = fixture.state(capture: capture, presenter: presenter)
        let original = CaptureDocument(image: fixture.image)
        app.lastDocument = original
        let task = Task { await app.capture(mode: .region) }
        try await waitUntil { await gate.started }
        await app.reopenLastCapture()
        XCTAssertTrue(presenter.activeDocument === original)
        await gate.release()
        await task.value
        XCTAssertTrue(capture.cancelled, "Navigation should cancel acquisition, not merely ignore its eventual result")
        XCTAssertTrue(presenter.activeDocument === original)
        XCTAssertEqual(presenter.presentCount, 0)
        XCTAssertEqual(app.phase, .editing)
    }

    func testOverlappingCaptureRequestsFreezeOnlyOnce() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let gate = RaceGate()
        let capture = RaceCaptureService(image: fixture.image, gate: gate)
        let presenter = RacePresenter()
        let app = fixture.state(capture: capture, presenter: presenter)
        // Exercise the preservation suspension as well as the capture suspension.
        app.lastDocument = CaptureDocument(image: fixture.image)
        let first = Task { await app.capture(mode: .region) }
        let second = Task { await app.capture(mode: .fullscreen) }
        try await waitUntil { await gate.started }
        XCTAssertEqual(capture.calls, 1)
        await gate.release()
        await first.value
        await second.value
        XCTAssertEqual(capture.calls, 1)
        XCTAssertEqual(presenter.presentCount, 1)
    }

    func testOldOCRCompletionCannotCloseNewerEditor() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let gate = RaceGate()
        let presenter = RacePresenter()
        let clipboard = RaceClipboard()
        let app = fixture.state(capture: RaceCaptureService(image: fixture.image), presenter: presenter,
                                clipboard: clipboard, recognizer: GatedRecognizer(gate: gate))
        await app.capture(mode: .ocr)
        let original = CaptureDocument(image: fixture.image)
        presenter.select(original, recognize: true)
        try await waitUntil { await gate.started }
        let next = CaptureDocument(image: fixture.image)
        app.lastDocument = next
        await app.reopenLastCapture()
        let dismissalsBeforeCompletion = presenter.dismissCount
        await gate.release()
        try await waitUntil { clipboard.text == "Recognized old capture" }
        XCTAssertTrue(presenter.activeDocument === next)
        XCTAssertEqual(presenter.dismissCount, dismissalsBeforeCompletion)
        XCTAssertEqual(app.phase, .editing)
    }

    func testImmediateCopyCompletionDoesNotCloseEditedRevision() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let gate = RaceGate()
        let presenter = RacePresenter()
        let clipboard = RaceClipboard()
        let app = fixture.state(capture: RaceCaptureService(image: fixture.image), presenter: presenter,
                                clipboard: clipboard, renderer: GatedRenderer(gate: gate))
        app.appSettings.immediateCopy = true
        await app.capture(mode: .region)
        let document = CaptureDocument(image: fixture.image)
        presenter.select(document)
        try await waitUntil { await gate.started }
        document.change { $0.crop = CGRect(x: 2, y: 3, width: 40, height: 20) }
        await gate.release()
        try await waitUntil { clipboard.png != nil }
        XCTAssertTrue(presenter.activeDocument === document)
        XCTAssertEqual(document.revision, 1)
        XCTAssertEqual(app.phase, .editing)
    }

    func testImmediateCopyCannotCloseReopenedInstanceWithSameUUID() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let gate = RaceGate()
        let presenter = RacePresenter()
        let clipboard = RaceClipboard()
        let app = fixture.state(capture: RaceCaptureService(image: fixture.image), presenter: presenter,
                                clipboard: clipboard, renderer: GatedRenderer(gate: gate))
        app.appSettings.immediateCopy = true
        await app.capture(mode: .region)
        let original = CaptureDocument(image: fixture.image)
        presenter.select(original)
        try await waitUntil { await gate.started }
        await app.reopenRecovery(original.id)
        let reopened = try XCTUnwrap(presenter.activeDocument)
        XCTAssertEqual(reopened.id, original.id)
        XCTAssertFalse(reopened === original)
        reopened.change { $0.crop = CGRect(x: 2, y: 3, width: 40, height: 20) }
        await gate.release()
        try await waitUntil { clipboard.png != nil }
        XCTAssertTrue(presenter.activeDocument === reopened)
        XCTAssertEqual(app.phase, .editing)
    }

    func testManualCopyClosesTheCurrentEditor() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let presenter = RacePresenter()
        let clipboard = RaceClipboard()
        let app = fixture.state(capture: RaceCaptureService(image: fixture.image), presenter: presenter, clipboard: clipboard)
        await app.capture(mode: .region)
        let document = CaptureDocument(image: fixture.image)
        presenter.select(document)

        presenter.copy()

        try await waitUntil { clipboard.png != nil }
        try await waitUntil { presenter.activeDocument == nil }
        XCTAssertEqual(app.phase, .idle)
    }

    func testManualSaveClosesTheCurrentEditor() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let presenter = RacePresenter()
        let app = fixture.state(capture: RaceCaptureService(image: fixture.image), presenter: presenter)
        app.appSettings.saveDirectory = fixture.root.appendingPathComponent("exports").path
        await app.capture(mode: .region)
        let document = CaptureDocument(image: fixture.image)
        presenter.select(document)

        presenter.save()

        try await waitUntil { document.savedURL != nil }
        try await waitUntil { presenter.activeDocument == nil }
        XCTAssertEqual(app.phase, .idle)
    }

    func testReopenSuspendedInPreservationCannotOverrideNewerCapture() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let recovery = RecoveryStore(root: fixture.root.appendingPathComponent("recovery"))
        let target = CaptureDocument(image: fixture.image)
        try await recovery.persist(id: target.id, image: target.image, edits: target.edits, revision: 0, savedURL: nil)
        let presenter = RacePresenter()
        let app = fixture.state(capture: RaceCaptureService(image: fixture.image), presenter: presenter, recovery: recovery)
        app.lastDocument = CaptureDocument(image: fixture.image)
        let queue = RecoveryQueueGate()
        defer { queue.release() }
        let hold = Task.detached { await recovery.holdForNavigationTest(queue) }
        try await waitUntil { queue.started }
        var navigationStarted = false
        let oldNavigation = Task { navigationStarted = true; await app.reopenRecovery(target.id) }
        try await waitUntil { navigationStarted }
        var captureStarted = false
        let newerCapture = Task { captureStarted = true; await app.capture(mode: .region) }
        try await waitUntil { captureStarted }
        queue.release()
        await hold.value
        await oldNavigation.value
        await newerCapture.value
        XCTAssertEqual(presenter.reopenCount, 0)
        XCTAssertEqual(presenter.presentCount, 1)
        XCTAssertEqual(app.phase, .editing)
    }

    func testRecoveryListRefreshCannotOverrideNewerCapture() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let recovery = RecoveryStore(root: fixture.root.appendingPathComponent("recovery"))
        let target = CaptureDocument(image: fixture.image)
        try await recovery.persist(id: target.id, image: target.image, edits: target.edits, revision: 0, savedURL: nil)
        let presenter = RacePresenter()
        let app = fixture.state(capture: RaceCaptureService(image: fixture.image), presenter: presenter, recovery: recovery)
        let queue = RecoveryQueueGate()
        defer { queue.release() }
        let hold = Task.detached { await recovery.holdForNavigationTest(queue) }
        try await waitUntil { queue.started }
        var navigationStarted = false
        let oldNavigation = Task { navigationStarted = true; await app.reopenLastCapture() }
        try await waitUntil { navigationStarted }
        await app.capture(mode: .region)
        queue.release()
        await hold.value
        await oldNavigation.value
        XCTAssertEqual(presenter.reopenCount, 0)
        XCTAssertEqual(presenter.presentCount, 1)
    }

    func testCloseCancelsPendingAcquisition() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let gate = RaceGate()
        let capture = RaceCaptureService(image: fixture.image, gate: gate)
        let presenter = RacePresenter()
        let app = fixture.state(capture: capture, presenter: presenter)
        let pending = Task { await app.capture(mode: .region) }
        try await waitUntil { await gate.started }
        app.closeEditor()
        await pending.value
        XCTAssertTrue(capture.cancelled)
        XCTAssertEqual(presenter.presentCount, 0)
        XCTAssertEqual(app.phase, .idle)
        XCTAssertNil(app.statusMessage)
    }

    func testCallerCancellationPropagatesToAcquisition() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let gate = RaceGate()
        let capture = RaceCaptureService(image: fixture.image, gate: gate)
        let presenter = RacePresenter()
        let app = fixture.state(capture: capture, presenter: presenter)
        let pending = Task { await app.capture(mode: .region) }
        try await waitUntil { await gate.started }
        pending.cancel()
        await pending.value
        XCTAssertTrue(capture.cancelled)
        XCTAssertEqual(presenter.presentCount, 0)
        XCTAssertEqual(app.phase, .idle)
        XCTAssertNil(app.statusMessage)
    }

    func testSuccessfulExportIsNotReportedAsFailedWhenRecoveryMaintenanceFails() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let recoveryRoot = fixture.root.appendingPathComponent("recovery")
        let presenter = RacePresenter()
        let app = fixture.state(capture: RaceCaptureService(image: fixture.image), presenter: presenter,
                                exporter: RecoveryBreakingExporter(recoveryRoot: recoveryRoot))
        app.appSettings.saveDirectory = fixture.root.appendingPathComponent("exports").path
        let document = CaptureDocument(image: fixture.image)
        app.lastDocument = document
        // Establish the original before the exporter deliberately breaks later
        // maintenance. Otherwise the fault injector races initial async recovery.
        let preserved = await app.preserve(document)
        XCTAssertTrue(preserved)
        await app.save(document)
        let export = try XCTUnwrap(document.savedURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: export.path))
        XCTAssertTrue(app.statusMessage?.hasPrefix("Saved to ") == true)
        XCTAssertFalse(app.statusMessage?.contains("Save failed") == true)
        XCTAssertTrue(app.lastDocument === document)
    }

    private func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw RaceFailure.timeout
    }
}

private enum RaceFailure: Error { case timeout }

private actor RaceGate {
    private(set) var started = false
    private var released = false
    func release() { released = true }
    func wait() async throws {
        started = true
        for _ in 0..<1000 {
            if released { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw RaceFailure.timeout
    }
}

private actor GatedRenderer: CaptureRendering {
    let gate: RaceGate
    let renderer = ImageRenderer()
    init(gate: RaceGate) { self.gate = gate }
    func render(_ request: RenderRequest) async throws -> RenderedCapture {
        try await gate.wait()
        return try await renderer.render(request)
    }
}

private actor GatedRecognizer: TextRecognizing {
    let gate: RaceGate
    init(gate: RaceGate) { self.gate = gate }
    func recognizeText(in image: CGImage) async throws -> String {
        try await gate.wait()
        return "Recognized old capture"
    }
}

@MainActor
private final class RaceCaptureService: ScreenCaptureProviding {
    let image: CGImage
    let gate: RaceGate?
    var calls = 0
    var cancelled = false
    init(image: CGImage, gate: RaceGate? = nil) { self.image = image; self.gate = gate }
    func freeze(mode: CaptureMode) async throws -> [FrozenScreen] {
        calls += 1
        do { try await gate?.wait() }
        catch { cancelled = error is CancellationError; throw error }
        return [FrozenScreen(id: 1, frame: CGRect(x: 0, y: 0, width: image.width, height: image.height), image: image, windows: [])]
    }
}

@MainActor
private final class RacePresenter: CapturePresenting {
    var activeDocument: CaptureDocument?
    var presentCount = 0
    var reopenCount = 0
    var dismissCount = 0
    private var onDocument: ((CaptureDocument) -> Void)?
    private var onCopy: ((CaptureDocument) -> Void)?
    private var onSave: ((CaptureDocument) -> Void)?
    private var onOCR: ((CaptureDocument) -> Void)?
    func select(_ document: CaptureDocument, recognize: Bool = false) {
        activeDocument = document
        onDocument?(document)
        if recognize { onOCR?(document) }
    }
    func copy() { if let document = activeDocument { onCopy?(document) } }
    func save() { if let document = activeDocument { onSave?(document) } }
    func present(screens: [FrozenScreen], mode: CaptureMode, style: CaptureStyle,
                 library: BackgroundLibrary, onDocument: @escaping (CaptureDocument) -> Void,
                 onCopy: @escaping (CaptureDocument) -> Void, onSave: @escaping (CaptureDocument) -> Void,
                 onOCR: @escaping (CaptureDocument) -> Void, onCancel: @escaping () -> Void,
                 onDiscard: @escaping (CaptureDocument) -> Void) {
        presentCount += 1
        self.onDocument = onDocument
        self.onCopy = onCopy
        self.onSave = onSave
        self.onOCR = onOCR
    }
    func reopen(document: CaptureDocument, library: BackgroundLibrary,
                onCopy: @escaping (CaptureDocument) -> Void, onSave: @escaping (CaptureDocument) -> Void,
                onCancel: @escaping () -> Void, onDocument: @escaping (CaptureDocument) -> Void,
                onDiscard: @escaping (CaptureDocument) -> Void) {
        reopenCount += 1
        activeDocument = document
        self.onDocument = onDocument
        self.onCopy = onCopy
        self.onSave = onSave
        onOCR = nil
    }
    func dismiss() { dismissCount += 1; activeDocument = nil }
    func showStatus(_ message: String, isError: Bool) { }
}

@MainActor
private final class RaceClipboard: CaptureClipboard {
    var png: Data?
    var text: String?
    func copyPNGData(_ data: Data) -> Bool { png = data; return true }
    func copyText(_ text: String) -> Bool { self.text = text; return true }
}

@MainActor
private struct Fixture {
    let root: URL
    let image: CGImage
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftShotRaceTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let context = try XCTUnwrap(CGContext(data: nil, width: 100, height: 60, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 60))
        image = try XCTUnwrap(context.makeImage())
    }
    func cleanUp() { try? FileManager.default.removeItem(at: root) }
    func state(capture: any ScreenCaptureProviding, presenter: RacePresenter,
               clipboard: RaceClipboard = RaceClipboard(), renderer: any CaptureRendering = ImageRenderer(),
               recognizer: any TextRecognizing = OCRService.shared, recovery: RecoveryStore? = nil,
               exporter: any CaptureExporting = ExportService()) -> AppState {
        AppState(defaults: UserDefaults(suiteName: "SwiftShotRaceTests.\(UUID())")!,
                 recovery: recovery ?? RecoveryStore(root: root.appendingPathComponent("recovery")),
                 backgrounds: BackgroundLibrary(rootURL: root.appendingPathComponent("backgrounds")),
                 exporter: exporter, clipboard: clipboard, presentsUI: false, persistUnsavedCaptures: true,
                 captureService: capture,
                 renderer: renderer, textRecognizer: recognizer, overlay: presenter)
    }
}

/// Holds the real actor before navigation reaches persist/records, providing a
/// deterministic suspension without modifying or replacing storage behavior.
private final class RecoveryQueueGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var didStart = false
    private var released = false
    var started: Bool { condition.lock(); defer { condition.unlock() }; return didStart }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
    func hold() {
        condition.lock()
        defer { condition.unlock() }
        didStart = true
        let deadline = Date().addingTimeInterval(10)
        while !released { if !condition.wait(until: deadline) { return } }
    }
}

extension RecoveryStore {
    fileprivate func holdForNavigationTest(_ gate: RecoveryQueueGate) { gate.hold() }
}

private struct RecoveryBreakingExporter: CaptureExporting {
    let recoveryRoot: URL
    func savePNGData(_ data: Data, to directory: String) throws -> URL {
        let saved = try ExportService().savePNGData(data, to: directory)
        try FileManager.default.removeItem(at: recoveryRoot)
        try Data("storage unavailable".utf8).write(to: recoveryRoot)
        return saved
    }
}
