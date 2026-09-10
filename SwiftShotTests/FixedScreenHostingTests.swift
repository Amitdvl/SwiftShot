import XCTest
import AppKit
import SwiftUI
@testable import SwiftShot

/// Runs the real controller's presentation path with synthetic pixels only.
/// No screen acquisition, mouse/key injection, user defaults, or user library.
@MainActor
final class FixedScreenHostingTests: XCTestCase {
    func testFixedScreenHostingDoesNotInstallContentDerivedWindowSizeLimits() async throws {
        let fixture = try makeFixture()
        defer { fixture.controller.dismiss() }

        // A fixed display overlay has controller-owned bounds. Attaching SwiftUI
        // must not replace the native panel's size policy with content-derived
        // minimum/ideal/maximum measurements on every selector/editor update.
        let unhosted = NSPanel(contentRect: fixture.screen.frame, styleMask: [.borderless],
            backing: .buffered, defer: false)
        unhosted.isReleasedWhenClosed = false
        defer { unhosted.close() }
        let nativeMinimum = unhosted.contentMinSize
        let nativeMaximum = unhosted.contentMaxSize

        let (panel, hosting) = try present(fixture)
        try await settle(hosting)
        assertDisplayBounds(panel, hosting: hosting, frame: fixture.screen.frame)
        XCTAssertEqual(panel.contentMinSize, nativeMinimum,
            "The selector installed content-derived minimum sizing despite a controller-owned fixed screen frame")
        // AppKit and SwiftUI may use different effectively-unlimited floating
        // point sentinels. Reject a content-derived cap, not its representation.
        XCTAssertGreaterThanOrEqual(panel.contentMaxSize.width, nativeMaximum.width,
            "The selector installed a content-derived maximum width")
        XCTAssertGreaterThanOrEqual(panel.contentMaxSize.height, nativeMaximum.height,
            "The selector installed a content-derived maximum height")

        let session = hosting.rootView.session
        session.select(screen: fixture.screen, crop: CGRect(x: 960, y: 540, width: 1920, height: 1080))
        session.activePopover = .annotations
        fixture.controller.showStatus("Synthetic fixed-screen hosting regression", isError: false)
        try await settle(hosting)
        assertDisplayBounds(panel, hosting: hosting, frame: fixture.screen.frame)
        XCTAssertEqual(panel.contentMinSize, nativeMinimum,
            "Editor/status changes reintroduced content-driven native minimum sizing")
        XCTAssertGreaterThanOrEqual(panel.contentMaxSize.width, nativeMaximum.width,
            "Editor/status changes reintroduced a content-derived maximum width")
        XCTAssertGreaterThanOrEqual(panel.contentMaxSize.height, nativeMaximum.height,
            "Editor/status changes reintroduced a content-derived maximum height")
    }

    func testFourKNativePixelsAndCoordinatesSurviveActualSelectorToEditorTransition() async throws {
        let fixture = try makeFixture()
        defer { fixture.controller.dismiss() }
        let (panel, hosting) = try present(fixture)
        try await settle(hosting)
        assertDisplayBounds(panel, hosting: hosting, frame: fixture.screen.frame)
        XCTAssertNil(fixture.controller.activeDocument)

        let selection = CGRect(x: 960, y: 540, width: 1920, height: 1080)
        hosting.rootView.session.select(screen: fixture.screen, crop: selection)
        try await settle(hosting)
        let document = try XCTUnwrap(fixture.controller.activeDocument)
        XCTAssertTrue(document.image === fixture.screen.image,
            "Fixed-screen UI sizing must retain the original pixels, not substitute a screen-sized resample")
        XCTAssertEqual(document.image.width, 3840)
        XCTAssertEqual(document.image.height, 2160)
        XCTAssertEqual(document.edits.crop, selection)
        assertDisplayBounds(panel, hosting: hosting, frame: fixture.screen.frame)

        // The hand-selected middle half of each pixel axis remains the middle
        // half of the displayed image, independently of the native screen size.
        let imageFrame = OverlayGeometry.imageFrame(imageSize: CGSize(width: 3840, height: 2160),
            screenSize: fixture.screen.frame.size)
        let points = OverlayGeometry.points(from: document.edits.crop, imageFrame: imageFrame,
            pixelSize: CGSize(width: document.image.width, height: document.image.height))
        XCTAssertEqual(points.midX, imageFrame.midX, accuracy: 0.0001)
        XCTAssertEqual(points.midY, imageFrame.midY, accuracy: 0.0001)
        XCTAssertEqual(points.width / imageFrame.width, 0.5, accuracy: 0.0001)
        XCTAssertEqual(points.height / imageFrame.height, 0.5, accuracy: 0.0001)
    }

    private struct Fixture {
        let controller: CaptureOverlayController
        let screen: FrozenScreen
        let library: BackgroundLibrary
    }

    private func makeFixture() throws -> Fixture {
        guard let display = NSScreen.main ?? NSScreen.screens.first else {
            throw XCTSkip("A native screen is required for the actual overlay panel regression")
        }
        let number = try XCTUnwrap(display.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
        let context = try XCTUnwrap(CGContext(data: nil, width: 3840, height: 2160,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.08, green: 0.12, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 3840, height: 2160))
        let image = try XCTUnwrap(context.makeImage())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftShot-FixedHosting-\(UUID())")
        let library = BackgroundLibrary(rootURL: root.appendingPathComponent("library"),
            bundleURL: root.appendingPathComponent("no-bundled-backgrounds"))
        let controller = CaptureOverlayController()
        var actions = CaptureActions()
        // Prevent dismiss from activating an unrelated foreground application.
        actions.returnApplication = NSRunningApplication.current
        controller.configure(actions: actions)
        return Fixture(controller: controller,
            screen: FrozenScreen(id: number.uint32Value, frame: display.frame, image: image, windows: []),
            library: library)
    }

    private func present(_ fixture: Fixture) throws -> (NSWindow, NSHostingView<CaptureOverlayView>) {
        let existing = Set(NSApp.windows.map { ObjectIdentifier($0) })
        fixture.controller.present(screens: [fixture.screen], mode: .region, style: CaptureStyle(),
            library: fixture.library, onDocument: { _ in }, onCopy: { _ in }, onSave: { _ in },
            onOCR: { _ in }, onCancel: {})
        // Resolve only a newly created panel carrying this exact synthetic source.
        // Never select, hide, resize, or close any preexisting application window.
        let owned = NSApp.windows.filter { window in
            guard !existing.contains(ObjectIdentifier(window)),
                  let hosting = window.contentView as? NSHostingView<CaptureOverlayView> else { return false }
            return hosting.rootView.screen.image === fixture.screen.image
        }
        XCTAssertEqual(owned.count, 1)
        let panel = try XCTUnwrap(owned.first)
        let hosting = try XCTUnwrap(panel.contentView as? NSHostingView<CaptureOverlayView>)
        // show() itself is exercised; subsequent layout checks stay invisible.
        panel.orderOut(nil)
        return (panel, hosting)
    }

    private func settle(_ hosting: NSView) async throws {
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        hosting.layoutSubtreeIfNeeded()
    }

    private func assertDisplayBounds(_ panel: NSWindow, hosting: NSView, frame: CGRect,
                                     file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(panel.isVisible, file: file, line: line)
        XCTAssertEqual(panel.frame, frame, "The controller's chosen display frame changed", file: file, line: line)
        XCTAssertEqual(panel.contentLayoutRect.size, frame.size, file: file, line: line)
        XCTAssertEqual(hosting.frame, CGRect(origin: .zero, size: frame.size), file: file, line: line)
        XCTAssertEqual(hosting.bounds, CGRect(origin: .zero, size: frame.size), file: file, line: line)
    }
}
