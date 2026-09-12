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
                       .init(headline: "Scroll the page", detail: "1 section captured", showsProgress: false,
                             finishEnabled: true))
        XCTAssertEqual(ScrollingCaptureHUDState.ready(sectionCount: 3).presentation.detail,
                       "3 sections captured")
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
        XCTAssertLessThanOrEqual(frame.width, 320)
        XCTAssertLessThanOrEqual(frame.height, 64)
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
              .init(headline: "Scroll the page", detail: "1 section captured", showsProgress: false,
                    finishEnabled: true), "ready copy should match the interaction contract")
        check(ScrollingCaptureHUDState.ready(sectionCount: 3).presentation.detail == "3 sections captured",
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
        check(frame.width <= 320 && frame.height <= 64, "HUD should remain compact")
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }
}
#endif
