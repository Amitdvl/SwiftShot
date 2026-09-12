import AppKit
import CoreGraphics
#if !DIRECT_SCROLLING_CAPTURE_HUD_TESTS
import XCTest
@testable import SwiftShot

final class ScrollingCaptureHUDTests: XCTestCase {
    @MainActor
    func testShowUsesFloatingNonactivatingPanelWithoutTakingKeyFocus() {
        let controller = ScrollingCaptureHUDController()
        let keyWindowBefore = NSApp.keyWindow
        let wasActive = NSApp.isActive

        controller.show(
            relativeTo: CGRect(x: 300, y: 240, width: 500, height: 400),
            in: CGRect(x: 0, y: 0, width: 1440, height: 900),
            onFinish: {},
            onCancel: {}
        )
        defer { controller.dismiss() }

        let panel = controller.panel
        XCTAssertNotNil(panel)
        XCTAssertTrue(panel?.styleMask.contains(.nonactivatingPanel) == true)
        XCTAssertTrue(panel?.styleMask.contains(.borderless) == true)
        XCTAssertEqual(panel?.level, .floating)
        XCTAssertFalse(panel?.isOpaque ?? true)
        XCTAssertFalse(panel?.isKeyWindow ?? true)
        XCTAssertTrue(NSApp.keyWindow === keyWindowBefore)
        XCTAssertEqual(NSApp.isActive, wasActive)
    }

    @MainActor
    func testStateCopyIsConciseAndActionable() {
        XCTAssertEqual(ScrollingCaptureHUDState.ready(sectionCount: 1).presentation,
                       .init(headline: "Keep scrolling", detail: "Preview updates live", showsProgress: false,
                             finishEnabled: true))
        XCTAssertEqual(ScrollingCaptureHUDState.ready(sectionCount: 3).presentation.detail,
                       "Preview updates live")
        XCTAssertEqual(ScrollingCaptureHUDState.recoverableSeam(sectionCount: 2).presentation,
                       .init(headline: "Scroll a little slower", detail: "The last view didn’t overlap enough.",
                             showsProgress: false, finishEnabled: true))
        XCTAssertEqual(ScrollingCaptureHUDState.terminal(reason: "The page size changed.", sectionCount: 4).presentation,
                       .init(headline: "Capture paused", detail: "The page size changed.", showsProgress: false,
                             finishEnabled: true))
        XCTAssertFalse(ScrollingCaptureHUDState.terminal(reason: "Screen Recording was revoked.", sectionCount: 0)
            .presentation.finishEnabled)
    }

    @MainActor
    func testLivePreviewExposesStableCaptureMeasurements() throws {
        let preview = ScrollingCapturePreview(
            image: try makeImage(width: 72, height: 127),
            acceptedFrames: 4,
            outputWidth: 1_440,
            outputHeight: 2_544,
            viewportHeight: 960
        )
        let controller = ScrollingCaptureHUDController()
        controller.show(relativeTo: .zero, in: CGRect(x: 0, y: 0, width: 900, height: 700),
                        onFinish: {}, onCancel: {})
        defer { controller.dismiss() }

        controller.update(preview)

        XCTAssertEqual(controller.model?.preview?.outputHeight, 2_544)
        XCTAssertEqual(preview.extentLabel, "2.7 screens · 2,544 px")
        XCTAssertEqual(preview.dimensionsLabel, "1,440 × 2,544 px")
    }

    @MainActor
    func testUpdateAndMouseActionsUseTheCurrentSessionCallbacks() {
        var staleFinishCount = 0
        var currentFinishCount = 0
        var cancelCount = 0
        let controller = ScrollingCaptureHUDController()
        controller.show(
            relativeTo: .zero,
            in: CGRect(x: 0, y: 0, width: 900, height: 700),
            onFinish: { staleFinishCount += 1 },
            onCancel: {}
        )
        controller.show(
            relativeTo: .zero,
            in: CGRect(x: 0, y: 0, width: 900, height: 700),
            onFinish: { currentFinishCount += 1 },
            onCancel: {}
        )
        controller.update(.ready(sectionCount: 2))
        XCTAssertEqual(controller.model?.state, .ready(sectionCount: 2))
        controller.performFinish()
        controller.performFinish()
        XCTAssertEqual(staleFinishCount, 0)
        XCTAssertEqual(currentFinishCount, 1)

        controller.show(
            relativeTo: .zero,
            in: CGRect(x: 0, y: 0, width: 900, height: 700),
            onFinish: {},
            onCancel: { cancelCount += 1 }
        )
        defer { controller.dismiss() }
        controller.performCancel()
        controller.performCancel()
        XCTAssertEqual(cancelCount, 1)
    }

    @MainActor
    func testPlacementAvoidsTheSelectionWhenVisibleSpaceExists() {
        let selection = CGRect(x: 320, y: 220, width: 500, height: 400)
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = ScrollingCaptureHUDPlacement.frame(selected: selection, visible: visible)

        XCTAssertTrue(visible.insetBy(dx: 8, dy: 8).contains(frame))
        XCTAssertFalse(frame.intersects(selection))
        XCTAssertLessThanOrEqual(frame.width, 400)
        XCTAssertLessThanOrEqual(frame.height, 120)
    }

    private func makeImage(width: Int, height: Int) throws -> CGImage {
        let bytes = [UInt8](repeating: 127, count: width * height * 4)
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
                .union(.byteOrder32Big), provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent))
    }
}
#else
@main
private enum DirectScrollingCaptureHUDTestRunner {
    @MainActor
    static func main() {
        _ = NSApplication.shared
        testShowUsesFloatingNonactivatingPanelWithoutTakingKeyFocus()
        testStateCopyIsConciseAndActionable()
        testUpdateAndMouseActionsUseTheCurrentSessionCallbacks()
        testPlacementAvoidsTheSelectionWhenVisibleSpaceExists()
        print("ScrollingCaptureHUDTests: 4 passed")
    }

    @MainActor
    private static func testShowUsesFloatingNonactivatingPanelWithoutTakingKeyFocus() {
        let controller = ScrollingCaptureHUDController()
        let keyWindowBefore = NSApp.keyWindow
        let wasActive = NSApp.isActive
        controller.show(relativeTo: CGRect(x: 300, y: 240, width: 500, height: 400),
                        in: CGRect(x: 0, y: 0, width: 1440, height: 900),
                        onFinish: {}, onCancel: {})
        defer { controller.dismiss() }
        check(controller.panel != nil, "show should create a panel")
        check(controller.panel?.styleMask.contains(.nonactivatingPanel) == true,
              "panel should be nonactivating")
        check(controller.panel?.styleMask.contains(.borderless) == true,
              "panel should be borderless")
        check(controller.panel?.level == .floating, "panel should float")
        check(controller.panel?.isOpaque == false, "panel should use a transparent backing")
        check(controller.panel?.isKeyWindow == false, "show should not make the HUD key")
        check(NSApp.keyWindow === keyWindowBefore, "show should preserve the key window")
        check(NSApp.isActive == wasActive, "show should preserve app activation")
    }

    @MainActor
    private static func testStateCopyIsConciseAndActionable() {
        check(ScrollingCaptureHUDState.ready(sectionCount: 1).presentation ==
              .init(headline: "Keep scrolling", detail: "Preview updates live", showsProgress: false,
                    finishEnabled: true), "ready copy should match the interaction contract")
        check(ScrollingCaptureHUDState.ready(sectionCount: 3).presentation.detail == "Preview updates live",
              "ready copy should pluralize sections")
        check(ScrollingCaptureHUDState.recoverableSeam(sectionCount: 2).presentation ==
              .init(headline: "Scroll a little slower", detail: "The last view didn’t overlap enough.",
                    showsProgress: false, finishEnabled: true),
              "recoverable seam copy should explain the recovery action")
        check(ScrollingCaptureHUDState.terminal(reason: "The page size changed.", sectionCount: 4).presentation ==
              .init(headline: "Capture paused", detail: "The page size changed.", showsProgress: false,
                    finishEnabled: true), "terminal copy should preserve the supplied reason")
        check(!ScrollingCaptureHUDState.terminal(reason: "Screen Recording was revoked.", sectionCount: 0)
            .presentation.finishEnabled, "terminal capture without verified pixels must disable Finish")
    }

    @MainActor
    private static func testUpdateAndMouseActionsUseTheCurrentSessionCallbacks() {
        var staleFinishCount = 0
        var currentFinishCount = 0
        var cancelCount = 0
        let controller = ScrollingCaptureHUDController()
        controller.show(relativeTo: .zero, in: CGRect(x: 0, y: 0, width: 900, height: 700),
                        onFinish: { staleFinishCount += 1 }, onCancel: {})
        controller.show(relativeTo: .zero, in: CGRect(x: 0, y: 0, width: 900, height: 700),
                        onFinish: { currentFinishCount += 1 }, onCancel: {})
        controller.update(.ready(sectionCount: 2))
        check(controller.model?.state == .ready(sectionCount: 2), "update should reach the visible model")
        controller.performFinish()
        controller.performFinish()
        check(staleFinishCount == 0, "re-showing should release the stale callback")
        check(currentFinishCount == 1, "Finish should call the current session once")

        controller.show(relativeTo: .zero, in: CGRect(x: 0, y: 0, width: 900, height: 700),
                        onFinish: {}, onCancel: { cancelCount += 1 })
        defer { controller.dismiss() }
        controller.performCancel()
        controller.performCancel()
        check(cancelCount == 1, "Cancel should call the current session once")
    }

    private static func testPlacementAvoidsTheSelectionWhenVisibleSpaceExists() {
        let selection = CGRect(x: 320, y: 220, width: 500, height: 400)
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = ScrollingCaptureHUDPlacement.frame(selected: selection, visible: visible)
        check(visible.insetBy(dx: 8, dy: 8).contains(frame), "HUD should remain on the visible display")
        check(!frame.intersects(selection), "HUD should avoid the captured selection when space exists")
        check(frame.width <= 400 && frame.height <= 120, "HUD should remain compact")
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }
}
#endif
