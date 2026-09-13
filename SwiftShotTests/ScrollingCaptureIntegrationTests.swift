import CoreGraphics
import XCTest
@testable import SwiftShot

@MainActor
final class ScrollingCaptureIntegrationTests: XCTestCase {
    func testScrollingSelectionStartsPassiveStreamAndFinishOpensNormalEditor() async throws {
        let fixture = try ScrollingIntegrationFixture()
        defer { fixture.cleanUp() }

        let started = await fixture.app.startScrollingCapture()
        XCTAssertTrue(started)
        XCTAssertEqual(fixture.overlay.actions.selectionPurpose, .scrolling)
        XCTAssertEqual(fixture.app.phase, .scrolling)

        fixture.overlay.selectFullRegion()
        await eventually { fixture.source.startCount == 1 && fixture.hud.isVisible }
        fixture.source.send(try fixture.frame(rows: 0..<6))
        fixture.source.send(try fixture.frame(rows: 2..<8))
        await eventually { fixture.hud.state == .ready(sectionCount: 2) }
        fixture.hud.finish()
        await eventually { fixture.app.lastDocument?.workflow == .scroll }

        let document = try XCTUnwrap(fixture.app.lastDocument)
        XCTAssertEqual(document.image.height, 8)
        XCTAssertTrue(fixture.overlay.activeDocument === document)
        XCTAssertEqual(fixture.source.stopCount, 1)
        XCTAssertFalse(fixture.hud.isVisible)
        XCTAssertEqual(fixture.app.phase, .editing)
    }

    func testScrollingCancelPublishesNothingAndReturnsIdle() async throws {
        let fixture = try ScrollingIntegrationFixture()
        defer { fixture.cleanUp() }

        let started = await fixture.app.startScrollingCapture()
        XCTAssertTrue(started)
        fixture.overlay.selectFullRegion()
        await eventually { fixture.source.startCount == 1 && fixture.hud.isVisible }
        fixture.source.send(try fixture.frame(rows: 0..<6))
        fixture.hud.cancel()
        await eventually { fixture.app.phase == .idle }

        XCTAssertNil(fixture.app.lastDocument)
        XCTAssertNil(fixture.overlay.activeDocument)
        XCTAssertEqual(fixture.source.stopCount, 1)
        XCTAssertFalse(fixture.hud.isVisible)
    }

    func testScrollingCancelKeepsCaptureOwnershipUntilSourceStopDrains() async throws {
        let fixture = try ScrollingIntegrationFixture()
        fixture.source.pauseStop = true
        defer {
            fixture.source.resumeStop()
            fixture.cleanUp()
        }

        let started = await fixture.app.startScrollingCapture()
        XCTAssertTrue(started)
        fixture.overlay.selectFullRegion()
        await eventually { fixture.source.startCount == 1 && fixture.hud.isVisible }
        fixture.hud.cancel()
        await eventually { fixture.source.stopHasBegun }

        XCTAssertEqual(fixture.app.phase, .scrolling)
        XCTAssertFalse(fixture.hud.isVisible)
        let replacementStarted = await fixture.app.startScrollingCapture()
        XCTAssertFalse(replacementStarted)
        XCTAssertEqual(fixture.source.startCount, 1)

        fixture.source.resumeStop()
        await eventually { fixture.app.phase == .idle }
        XCTAssertEqual(fixture.source.stopCount, 1)
    }

    func testCloseEditorKeepsCaptureOwnershipUntilSourceStopDrains() async throws {
        let fixture = try ScrollingIntegrationFixture()
        fixture.source.pauseStop = true
        defer {
            fixture.source.resumeStop()
            fixture.cleanUp()
        }

        let started = await fixture.app.startScrollingCapture()
        XCTAssertTrue(started)
        fixture.overlay.selectFullRegion()
        await eventually { fixture.source.startCount == 1 && fixture.hud.isVisible }
        fixture.app.closeEditor()
        await eventually { fixture.source.stopHasBegun }

        XCTAssertEqual(fixture.app.phase, .scrolling)
        let replacementStarted = await fixture.app.startScrollingCapture()
        XCTAssertFalse(replacementStarted)
        XCTAssertEqual(fixture.source.startCount, 1)

        fixture.source.resumeStop()
        await eventually { fixture.app.phase == .idle }
        XCTAssertEqual(fixture.source.stopCount, 1)
    }

    func testScrollingFinishPreservesPrivateLineage() async throws {
        let fixture = try ScrollingIntegrationFixture()
        defer { fixture.cleanUp() }
        fixture.app.appSettings.privateCapture = true

        let started = await fixture.app.startScrollingCapture()
        XCTAssertTrue(started)
        fixture.overlay.selectFullRegion()
        await eventually { fixture.source.startCount == 1 && fixture.hud.isVisible }
        fixture.source.send(try fixture.frame(rows: 0..<6))
        await eventually { fixture.hud.state == .ready(sectionCount: 1) }
        fixture.hud.finish()
        await eventually { fixture.app.lastDocument?.workflow == .scroll }

        XCTAssertTrue(try XCTUnwrap(fixture.app.lastDocument).isPrivate)
        XCTAssertNil(fixture.app.appSettings.lastRegion)
    }

    private func eventually(_ predicate: @escaping @MainActor () -> Bool) async {
        for _ in 0..<200 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Condition did not become true")
    }
}

@MainActor
private final class ScrollingIntegrationFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftShotScrolling-\(UUID())")
    let suiteName = "SwiftShotScrolling.\(UUID())"
    let defaults: UserDefaults
    let screen: FrozenScreen
    let source = IntegrationScrollingSource()
    let hud = IntegrationScrollingHUD()
    let overlay = IntegrationScrollingOverlay()
    let app: AppState

    init() throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let image = try Self.makeImage(rows: 0..<6)
        screen = FrozenScreen(id: 42, frame: CGRect(x: 0, y: 0, width: 6, height: 6), image: image, windows: [])
        overlay.screen = screen
        let source = self.source
        app = AppState(defaults: defaults,
            recovery: RecoveryStore(root: root.appendingPathComponent("recovery")),
            backgrounds: BackgroundLibrary(rootURL: root.appendingPathComponent("backgrounds")),
            presentsUI: false, captureService: IntegrationCaptureService(screen: screen),
            overlay: overlay, diagnostics: nil, scrollingFrameSourceFactory: { source },
            scrollingHUD: hud)
    }

    func frame(rows: Range<Int>) throws -> ScrollingCaptureFrame {
        ScrollingCaptureFrame(image: try Self.makeImage(rows: rows), pointPixelScale: 1)
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    private static func makeImage(rows: Range<Int>) throws -> CGImage {
        let width = 6
        var bytes = [UInt8]()
        for row in rows {
            for x in 0..<width {
                bytes += [UInt8((row * 37 + x * 17) % 251), UInt8((row * 67 + x * 29 + 11) % 253),
                          UInt8((row * 97 + x * 43 + 23) % 255), 255]
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: rows.count, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
                .union(.byteOrder32Big), provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent))
    }
}

@MainActor
private struct IntegrationCaptureService: ScreenCaptureProviding {
    let screen: FrozenScreen
    func freeze(mode: CaptureMode) async throws -> [FrozenScreen] { [screen] }
}

@MainActor
private final class IntegrationScrollingOverlay: CapturePresenting {
    var screen: FrozenScreen?
    var actions = CaptureActions()
    private(set) var activeDocument: CaptureDocument?
    func configure(actions: CaptureActions) { self.actions = actions }
    func selectFullRegion() { actions.selectedRegion(screen!, CGRect(x: 0, y: 0, width: 6, height: 6)) }
    func present(screens: [FrozenScreen], mode: CaptureMode, style: CaptureStyle,
                 library: BackgroundLibrary, onDocument: @escaping (CaptureDocument) -> Void,
                 onCopy: @escaping (CaptureDocument) -> Void, onSave: @escaping (CaptureDocument) -> Void,
                 onOCR: @escaping (CaptureDocument) -> Void, onCancel: @escaping () -> Void,
                 onDiscard: @escaping (CaptureDocument) -> Void) {}
    func reopen(document: CaptureDocument, library: BackgroundLibrary,
                onCopy: @escaping (CaptureDocument) -> Void, onSave: @escaping (CaptureDocument) -> Void,
                onCancel: @escaping () -> Void, onDocument: @escaping (CaptureDocument) -> Void,
                onDiscard: @escaping (CaptureDocument) -> Void) { activeDocument = document }
    func dismiss() { activeDocument = nil }
    func showStatus(_ message: String, isError: Bool) {}
}

@MainActor
private final class IntegrationScrollingSource: ScrollingFrameSource {
    private var continuation: AsyncThrowingStream<ScrollingCaptureFrame, Error>.Continuation?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var stopHasBegun = false
    var pauseStop = false
    private var stopContinuation: CheckedContinuation<Void, Never>?
    func start(for region: CaptureRegionReference) async throws -> AsyncThrowingStream<ScrollingCaptureFrame, Error> {
        startCount += 1
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(3)) { continuation = $0 }
    }
    func stop() async {
        guard let continuation else { return }
        stopCount += 1
        stopHasBegun = true
        if pauseStop {
            await withCheckedContinuation { stopContinuation = $0 }
        }
        self.continuation = nil
        continuation.finish()
    }
    func send(_ frame: ScrollingCaptureFrame) { continuation?.yield(frame) }
    func resumeStop() {
        pauseStop = false
        stopContinuation?.resume()
        stopContinuation = nil
    }
}

@MainActor
private final class IntegrationScrollingHUD: ScrollingCaptureHUDPresenting {
    private(set) var isVisible = false
    private(set) var state: ScrollingCaptureHUDState = .preparing
    private(set) var extent: ScrollingCaptureExtent?
    private var onFinish: (() -> Void)?
    private var onCancel: (() -> Void)?
    func show(relativeTo selectedFrame: CGRect, on displayFrame: CGRect, in visibleFrame: CGRect,
              onFinish: @escaping @MainActor () -> Void,
              onCancel: @escaping @MainActor () -> Void) {
        isVisible = true; self.onFinish = onFinish; self.onCancel = onCancel
    }
    func update(_ state: ScrollingCaptureHUDState) { self.state = state }
    func update(_ extent: ScrollingCaptureExtent) { self.extent = extent }
    func dismiss() { isVisible = false; onFinish = nil; onCancel = nil }
    func finish() { onFinish?() }
    func cancel() { onCancel?() }
}
