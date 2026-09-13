import AppKit
import CoreGraphics
#if !DIRECT_SCROLLING_CAPTURE_HUD_TESTS
import XCTest
@testable import SwiftShot

final class ScrollingCaptureHUDTests: XCTestCase {
    @MainActor
    func testShowUsesPassiveSpotlightAndFloatingControlsWithoutTakingKeyFocus() {
        let controller = ScrollingCaptureHUDController()
        let keyWindowBefore = NSApp.keyWindow
        let wasActive = NSApp.isActive

        controller.show(
            relativeTo: CGRect(x: 300, y: 240, width: 500, height: 400),
            on: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            in: CGRect(x: 0, y: 0, width: 1440, height: 900),
            onFinish: {},
            onCancel: {}
        )
        defer { controller.dismiss() }

        let panel = controller.panel
        let spotlight = controller.spotlightPanel
        XCTAssertNotNil(panel)
        XCTAssertNotNil(spotlight)
        XCTAssertTrue(panel?.styleMask.contains(.nonactivatingPanel) == true)
        XCTAssertTrue(panel?.styleMask.contains(.borderless) == true)
        XCTAssertTrue(spotlight?.styleMask.contains(.nonactivatingPanel) == true)
        XCTAssertTrue(spotlight?.styleMask.contains(.borderless) == true)
        XCTAssertEqual(spotlight?.level, .floating)
        if let panel, let spotlight {
            XCTAssertLessThan(spotlight.level.rawValue, panel.level.rawValue)
        }
        XCTAssertEqual(spotlight?.frame, CGRect(x: 0, y: 0, width: 1_440, height: 900))
        XCTAssertTrue(spotlight?.ignoresMouseEvents == true)
        XCTAssertFalse(panel?.isOpaque ?? true)
        XCTAssertFalse(spotlight?.isOpaque ?? true)
        XCTAssertFalse(panel?.isKeyWindow ?? true)
        XCTAssertFalse(spotlight?.isKeyWindow ?? true)
        XCTAssertTrue(NSApp.keyWindow === keyWindowBefore)
        XCTAssertEqual(NSApp.isActive, wasActive)
    }

    @MainActor
    func testStateCopyIsConciseAndActionable() {
        XCTAssertEqual(ScrollingCaptureHUDState.ready(sectionCount: 1).presentation,
                       .init(headline: "Keep scrolling", detail: "The spotlight tracks your capture",
                             showsProgress: false,
                             finishEnabled: true))
        XCTAssertEqual(ScrollingCaptureHUDState.ready(sectionCount: 3).presentation.detail,
                       "The spotlight tracks your capture")
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
    func testExtentUpdateMovesStableMeasurementOntoTheSpotlight() {
        let extent = ScrollingCaptureExtent(
            acceptedFrames: 4,
            outputWidth: 1_440,
            outputHeight: 2_544,
            viewportHeight: 960
        )
        let controller = ScrollingCaptureHUDController()
        controller.show(relativeTo: .zero, on: CGRect(x: 0, y: 0, width: 900, height: 700),
                        in: CGRect(x: 0, y: 0, width: 900, height: 700),
                        onFinish: {}, onCancel: {})
        defer { controller.dismiss() }

        controller.update(extent)

        XCTAssertEqual(controller.model?.extent?.outputHeight, 2_544)
        XCTAssertEqual(controller.spotlightView?.extent?.outputHeight, 2_544)
        XCTAssertEqual(extent.extentLabel, "2.7 screens · 2,544 px")
        XCTAssertEqual(extent.dimensionsLabel, "1,440 × 2,544 px")
    }

    func testSpotlightGeometryConvertsAndClipsTheScreenSelection() {
        let overlay = CGRect(x: -500, y: 100, width: 1_000, height: 700)
        let selected = CGRect(x: -420, y: 160, width: 760, height: 520)

        XCTAssertEqual(
            ScrollingCaptureSpotlightGeometry.localSelection(selected: selected, overlay: overlay),
            CGRect(x: 80, y: 60, width: 760, height: 520)
        )
        XCTAssertEqual(
            ScrollingCaptureSpotlightGeometry.localSelection(
                selected: CGRect(x: -600, y: 50, width: 1_200, height: 900), overlay: overlay),
            CGRect(x: 0, y: 0, width: 1_000, height: 700)
        )
    }

    @MainActor
    func testUpdateAndMouseActionsUseTheCurrentSessionCallbacks() {
        var staleFinishCount = 0
        var currentFinishCount = 0
        var cancelCount = 0
        let controller = ScrollingCaptureHUDController()
        controller.show(
            relativeTo: .zero,
            on: CGRect(x: 0, y: 0, width: 900, height: 700),
            in: CGRect(x: 0, y: 0, width: 900, height: 700),
            onFinish: { staleFinishCount += 1 },
            onCancel: {}
        )
        controller.show(
            relativeTo: .zero,
            on: CGRect(x: 0, y: 0, width: 900, height: 700),
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
            on: CGRect(x: 0, y: 0, width: 900, height: 700),
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
        XCTAssertLessThanOrEqual(frame.width, 340)
        XCTAssertLessThanOrEqual(frame.height, 72)
    }
}
#else
@main
private enum DirectScrollingCaptureHUDTestRunner {
    @MainActor
    static func main() {
        _ = NSApplication.shared
        testShowUsesPassiveSpotlightAndFloatingControlsWithoutTakingKeyFocus()
        testStateCopyIsConciseAndActionable()
        testUpdateAndMouseActionsUseTheCurrentSessionCallbacks()
        testPlacementAvoidsTheSelectionWhenVisibleSpaceExists()
        print("ScrollingCaptureHUDTests: 4 passed")
    }

    @MainActor
    private static func testShowUsesPassiveSpotlightAndFloatingControlsWithoutTakingKeyFocus() {
        let controller = ScrollingCaptureHUDController()
        let keyWindowBefore = NSApp.keyWindow
        let wasActive = NSApp.isActive
        controller.show(relativeTo: CGRect(x: 300, y: 240, width: 500, height: 400),
                        on: CGRect(x: 0, y: 0, width: 1_440, height: 900),
                        in: CGRect(x: 0, y: 0, width: 1440, height: 900),
                        onFinish: {}, onCancel: {})
        defer { controller.dismiss() }
        check(controller.panel != nil, "show should create a panel")
        check(controller.spotlightPanel != nil, "show should create the passive spotlight")
        check(controller.panel?.styleMask.contains(.nonactivatingPanel) == true,
              "panel should be nonactivating")
        check(controller.panel?.styleMask.contains(.borderless) == true,
              "panel should be borderless")
        check(controller.spotlightPanel?.level == .floating, "spotlight should float")
        if let panel = controller.panel, let spotlight = controller.spotlightPanel {
            check(panel.level.rawValue > spotlight.level.rawValue,
                  "controls should stay above the spotlight")
        }
        check(controller.spotlightPanel?.ignoresMouseEvents == true,
              "spotlight must pass scrolling and pointer input through")
        check(controller.panel?.isOpaque == false, "panel should use a transparent backing")
        check(controller.panel?.isKeyWindow == false, "show should not make the HUD key")
        check(NSApp.keyWindow === keyWindowBefore, "show should preserve the key window")
        check(NSApp.isActive == wasActive, "show should preserve app activation")
    }

    @MainActor
    private static func testStateCopyIsConciseAndActionable() {
        check(ScrollingCaptureHUDState.ready(sectionCount: 1).presentation ==
              .init(headline: "Keep scrolling", detail: "The spotlight tracks your capture",
                    showsProgress: false,
                    finishEnabled: true), "ready copy should match the interaction contract")
        check(ScrollingCaptureHUDState.ready(sectionCount: 3).presentation.detail ==
              "The spotlight tracks your capture", "ready copy should explain the spotlight")
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
        controller.show(relativeTo: .zero, on: CGRect(x: 0, y: 0, width: 900, height: 700),
                        in: CGRect(x: 0, y: 0, width: 900, height: 700),
                        onFinish: { staleFinishCount += 1 }, onCancel: {})
        controller.show(relativeTo: .zero, on: CGRect(x: 0, y: 0, width: 900, height: 700),
                        in: CGRect(x: 0, y: 0, width: 900, height: 700),
                        onFinish: { currentFinishCount += 1 }, onCancel: {})
        controller.update(.ready(sectionCount: 2))
        check(controller.model?.state == .ready(sectionCount: 2), "update should reach the visible model")
        controller.performFinish()
        controller.performFinish()
        check(staleFinishCount == 0, "re-showing should release the stale callback")
        check(currentFinishCount == 1, "Finish should call the current session once")

        controller.show(relativeTo: .zero, on: CGRect(x: 0, y: 0, width: 900, height: 700),
                        in: CGRect(x: 0, y: 0, width: 900, height: 700),
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
        check(frame.width <= 340 && frame.height <= 72, "HUD should remain compact")
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }
}
#endif
