import AppKit
import XCTest
@testable import SwiftShot

@MainActor
final class CaptureFreezeRecoveryTests: XCTestCase {
    // Break: a lost native completion holds phase=.freezing forever, blocks the
    // retry, or later publishes obsolete pixels over the successful new session.
    func testStalledCaptureTimesOutAllowsRetryAndRejectsLateOldPixels() async throws {
        let fixture = try FreezeFixture()
        defer { fixture.cleanUp() }
        let entered = expectation(description: "First native acquisition entered")
        let returned = expectation(description: "Stalled capture returned through timeout")
        let capture = FreezeNativeService(image: fixture.image, entered: entered)
        let presenter = FreezePresenter()
        let app = fixture.state(capture: capture, presenter: presenter, timeout: .milliseconds(40))
        var firstSucceeded: Bool?
        let first = Task { firstSucceeded = await app.capture(mode: .region); returned.fulfill() }
        defer { first.cancel(); capture.releaseFirst() }
        await fulfillment(of: [entered, returned], timeout: 2)
        XCTAssertEqual(firstSucceeded, false, "Timeout must return failure before the native callback arrives")
        XCTAssertEqual(app.phase, .idle)
        XCTAssertFalse(app.isCapturing)
        XCTAssertNotNil(app.statusMessage)
        XCTAssertEqual(presenter.presentedIDs, [])
        guard app.phase == .idle else { capture.releaseFirst(); return }

        let retrySucceeded = await app.capture(mode: .region)
        XCTAssertTrue(retrySucceeded)
        XCTAssertEqual(app.phase, .editing)
        XCTAssertNil(app.statusMessage)
        XCTAssertEqual(presenter.presentedIDs, [2])
        let current = CaptureDocument(image: fixture.image)
        app.lastDocument = current
        await app.reopenLastCapture()
        XCTAssertTrue(presenter.activeDocument === current)

        capture.releaseFirst()
        await fulfillment(of: [capture.firstFinished], timeout: 1)
        await first.value
        // Drain the old task's observer so late publication has a chance to run.
        await Task.yield()
        XCTAssertEqual(presenter.presentedIDs, [2])
        XCTAssertTrue(presenter.activeDocument === current)
        XCTAssertEqual(app.phase, .editing)
        XCTAssertNil(app.statusMessage)
    }

    // Break: AppState's outer cancellation handler forwards cancel but awaits a
    // callback indefinitely, leaving all capture commands disabled.
    func testCallerCancellationRestoresIdleBeforeNativeCompletion() async throws {
        let fixture = try FreezeFixture()
        defer { fixture.cleanUp() }
        let entered = expectation(description: "Native acquisition entered")
        let returned = expectation(description: "Cancelled capture returned")
        let capture = FreezeNativeService(image: fixture.image, entered: entered)
        let presenter = FreezePresenter()
        let app = fixture.state(capture: capture, presenter: presenter, timeout: .seconds(30))
        let pending = Task { await app.capture(mode: .region); returned.fulfill() }
        defer { pending.cancel(); capture.releaseFirst() }
        await fulfillment(of: [entered], timeout: 1)
        pending.cancel()
        await fulfillment(of: [returned], timeout: 1)
        XCTAssertEqual(app.phase, .idle)
        XCTAssertFalse(app.isCapturing)
        XCTAssertNil(app.statusMessage)
        XCTAssertEqual(presenter.presentedIDs, [])
        capture.releaseFirst()
        await fulfillment(of: [capture.firstFinished], timeout: 1)
        await pending.value
        XCTAssertEqual(presenter.presentedIDs, [])
        XCTAssertEqual(app.phase, .idle)
    }
}

@MainActor
private final class FreezeNativeService: ScreenCaptureProviding {
    let image: CGImage
    let entered: XCTestExpectation
    let firstFinished = XCTestExpectation(description: "Old native acquisition finally finished")
    private var calls = 0
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    init(image: CGImage, entered: XCTestExpectation) { self.image = image; self.entered = entered }
    func freeze(mode: CaptureMode) async throws -> [FrozenScreen] {
        calls += 1
        let id = calls
        if id == 1 {
            entered.fulfill()
            if !released { await withCheckedContinuation { continuation = $0 } }
            firstFinished.fulfill()
        }
        // The SDK double intentionally returns pixels even when cancelled.
        // The real session boundary must reject them, rather than trusting it.
        return [FrozenScreen(id: UInt32(id), frame: CGRect(x: 0, y: 0, width: 8, height: 8), image: image, windows: [])]
    }
    func releaseFirst() { released = true; continuation?.resume(); continuation = nil }
}

@MainActor
private final class FreezePresenter: CapturePresenting {
    var activeDocument: CaptureDocument?
    var presentedIDs: [CGDirectDisplayID] = []
    func present(screens: [FrozenScreen], mode: CaptureMode, style: CaptureStyle,
                 library: BackgroundLibrary, onDocument: @escaping (CaptureDocument) -> Void,
                 onCopy: @escaping (CaptureDocument) -> Void, onSave: @escaping (CaptureDocument) -> Void,
                 onOCR: @escaping (CaptureDocument) -> Void, onCancel: @escaping () -> Void,
                 onDiscard: @escaping (CaptureDocument) -> Void) {
        presentedIDs.append(contentsOf: screens.map(\.id))
    }
    func reopen(document: CaptureDocument, library: BackgroundLibrary,
                onCopy: @escaping (CaptureDocument) -> Void, onSave: @escaping (CaptureDocument) -> Void,
                onCancel: @escaping () -> Void, onDocument: @escaping (CaptureDocument) -> Void,
                onDiscard: @escaping (CaptureDocument) -> Void) { activeDocument = document }
    func dismiss() { activeDocument = nil }
    func showStatus(_ message: String, isError: Bool) { }
}

@MainActor
private struct FreezeFixture {
    let root: URL
    let defaults: UserDefaults
    let defaultsName: String
    let image: CGImage
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftShotFreezeTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaultsName = "SwiftShotFreezeTests.\(UUID())"
        defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
            bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        image = try XCTUnwrap(context.makeImage())
    }
    func state(capture: any ScreenCaptureProviding, presenter: FreezePresenter, timeout: Duration) -> AppState {
        AppState(defaults: defaults, recovery: RecoveryStore(root: root.appendingPathComponent("recovery")),
                 backgrounds: BackgroundLibrary(rootURL: root.appendingPathComponent("backgrounds")),
                 presentsUI: false, captureService: capture, captureTimeout: timeout, overlay: presenter,
                 diagnostics: nil)
    }
    func cleanUp() {
        defaults.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: root)
    }
}
