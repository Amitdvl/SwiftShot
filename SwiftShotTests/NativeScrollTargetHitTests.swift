import AppKit
import CoreGraphics
import XCTest
@testable import SwiftShot

/// The native window hit is real; only the proposed target's AX frame/owner are
/// supplied from this test's own window. No AX permission, screen pixels, input,
/// clipboard, installed application or other application's window is operated.
@MainActor
final class NativeScrollTargetHitTests: XCTestCase {
    func testPublicBoundMetadataQueryTracksOnlyVisibleOriginalWindow() async throws {
        let fixture = try NativeScrollHitFixture()
        defer { fixture.close() }
        try await fixture.showUnderlyingWindow()
        let id = try XCTUnwrap(CGWindowID(exactly: fixture.underlying.windowNumber))
        let metadata = try XCTUnwrap(ScrollTargetWindowMetadata.readBound(windowID: id))
        XCTAssertEqual(metadata.id, id)
        XCTAssertEqual(metadata.ownerPID, fixture.ownerPID)
        XCTAssertEqual(metadata.frame, CGRect(origin: fixture.quartz(CGPoint(x: fixture.underlying.frame.minX,
            y: fixture.underlying.frame.maxY)), size: fixture.underlying.frame.size))
        XCTAssertEqual(metadata.alpha, 1)
        XCTAssertTrue(metadata.isOnScreen)

        fixture.underlying.orderOut(nil)
        var hidden = ScrollTargetWindowMetadata.readBound(windowID: id)
        for _ in 0..<50 where hidden != nil {
            try await Task.sleep(for: .milliseconds(10))
            hidden = ScrollTargetWindowMetadata.readBound(windowID: id)
        }
        XCTAssertNil(hidden, "The targeted query may return an off-screen row, but production must not accept it")
        try await fixture.showUnderlyingWindow()
        XCTAssertEqual(ScrollTargetWindowMetadata.readBound(windowID: id)?.id, id,
            "Visibility restoration of the exact original owned ID must work after the negative control")
    }

    // Break: rectangle-first occlusion rejects a real underlying input target
    // merely because an opaque-looking, mouse-ignoring window covers its point.
    func testMouseIgnoringOverlayAllowsUnderlyingNativeHitWindow() async throws {
        let fixture = try NativeScrollHitFixture()
        defer { fixture.close() }
        try await fixture.showUnderlyingWindow()
        fixture.showOverlay(appearance: .opaque, ignoresMouseEvents: false)
        let interceptingHit = try await fixture.waitForHit(at: fixture.targetPoint,
            expected: fixture.overlay.windowNumber)
        XCTAssertEqual(interceptingHit, fixture.overlay.windowNumber,
            "Positive control: the same visible opaque overlay must intercept before mouse ignoring is enabled")
        // Change only input transparency, after native interception was proved.
        fixture.overlay.ignoresMouseEvents = true

        let hit = try await fixture.waitForHit(at: fixture.targetPoint,
            expected: fixture.underlying.windowNumber)
        let snapshot = try fixture.snapshot()
        XCTAssertEqual(snapshot.overlay.alpha, 1)
        XCTAssertTrue(snapshot.overlay.frame.contains(fixture.quartz(fixture.targetPoint)))
        XCTAssertNotEqual(snapshot.overlay.id, snapshot.underlying.id)
        XCTAssertEqual(hit, Int(snapshot.underlying.id))

        let resolved = ScrollTargetWindowPolicy.resolve(
            point: fixture.quartz(fixture.targetPoint), ownerPID: fixture.ownerPID,
            axWindowFrame: snapshot.underlying.frame, mouseHitWindowNumber: hit,
            windows: [snapshot.overlay, snapshot.underlying])

        XCTAssertEqual(resolved, snapshot.underlying.id,
            "A covering rectangle is not an input target when its actual window ignores mouse events")
    }

    // Break: treating visual transparency or Quartz row order as input authority
    // bypasses the actual native recipient. Some native configurations still
    // intercept at clear pixels; that is not permission to scroll beneath them.
    func testTransparentPixelsDoNotOverrideNativeInputRecipient() async throws {
        let fixture = try NativeScrollHitFixture()
        defer { fixture.close() }
        try await fixture.showUnderlyingWindow()
        fixture.showOverlay(appearance: .transparentRightHalf, ignoresMouseEvents: false)
        try await fixture.verifyTransparentDrawingPreconditions()

        let opaqueHit = try await fixture.waitForHit(at: fixture.opaqueControlPoint,
            expected: fixture.overlay.windowNumber)
        let observedClearHit = NSWindow.windowNumber(at: fixture.targetPoint, belowWindowWithWindowNumber: 0)
        let clearHit = try XCTUnwrap([fixture.underlying.windowNumber, fixture.overlay.windowNumber].contains(observedClearHit)
            ? observedClearHit : nil, "The clear-point observation must identify one of the two owned windows")
        let snapshot = try fixture.snapshot()
        XCTAssertEqual(snapshot.overlay.alpha, 1,
            "The native clear point must not be simulated by fading the entire window to alpha zero")
        XCTAssertTrue(snapshot.overlay.frame.contains(fixture.quartz(fixture.targetPoint)))
        XCTAssertTrue(snapshot.overlay.frame.contains(fixture.quartz(fixture.opaqueControlPoint)))
        XCTAssertFalse(fixture.overlay.ignoresMouseEvents)
        XCTAssertEqual(opaqueHit, Int(snapshot.overlay.id))
        let expected: CGWindowID? = clearHit == Int(snapshot.underlying.id) ? snapshot.underlying.id : nil
        NSLog("NativeScrollTransparentBoundary: clear-point recipient=%@; underlying target must %@",
            expected == nil ? "overlay" : "underlying", expected == nil ? "be rejected" : "bind exactly")
        for rows in [[snapshot.overlay, snapshot.underlying], [snapshot.underlying, snapshot.overlay]] {
            let clearResolved = ScrollTargetWindowPolicy.resolve(
                point: fixture.quartz(fixture.targetPoint), ownerPID: fixture.ownerPID,
                axWindowFrame: snapshot.underlying.frame, mouseHitWindowNumber: clearHit, windows: rows)
            XCTAssertEqual(clearResolved, expected,
                "Only the independently observed native hit authorizes the underlying target, never pixel transparency or row order")

            let opaqueResolved = ScrollTargetWindowPolicy.resolve(
                point: fixture.quartz(fixture.opaqueControlPoint), ownerPID: fixture.ownerPID,
                axWindowFrame: snapshot.underlying.frame, mouseHitWindowNumber: opaqueHit, windows: rows)
            XCTAssertNil(opaqueResolved,
                "An actual intercepting window must not authorize the underlying AX target")
        }
    }

    // Break: PID-only or AX-owner/frame-only matching scrolls an underlying
    // window even though another window in that same process intercepts input.
    func testMouseAcceptingAXIgnoredSameProcessOverlayRejectsUnderlyingWindow() async throws {
        let fixture = try NativeScrollHitFixture()
        defer { fixture.close() }
        try await fixture.showUnderlyingWindow()
        fixture.showOverlay(appearance: .opaque, ignoresMouseEvents: false)
        // This controls this test's own accessibility exposure only. No global
        // AX hit is needed or claimed; native input interception is the oracle.
        fixture.overlay.setAccessibilityElement(false)
        fixture.overlay.contentView?.setAccessibilityElement(false)
        XCTAssertFalse(fixture.overlay.isAccessibilityElement(),
            "Fixture precondition: the intercepting window is declared AX-ignored")

        let hit = try await fixture.waitForHit(at: fixture.targetPoint,
            expected: fixture.overlay.windowNumber)
        let snapshot = try fixture.snapshot()
        XCTAssertEqual(snapshot.overlay.ownerPID, snapshot.underlying.ownerPID)
        XCTAssertNotEqual(snapshot.overlay.id, snapshot.underlying.id)
        XCTAssertEqual(hit, Int(snapshot.overlay.id))

        let resolved = ScrollTargetWindowPolicy.resolve(
            point: fixture.quartz(fixture.targetPoint), ownerPID: fixture.ownerPID,
            axWindowFrame: snapshot.underlying.frame, mouseHitWindowNumber: hit,
            windows: [snapshot.overlay, snapshot.underlying])

        XCTAssertNil(resolved,
            "An event-intercepting window is not the requested underlying window merely because both have the same PID")
    }
}

@MainActor
private final class NativeScrollHitFixture {
    enum Appearance { case opaque, transparentRightHalf }

    struct Snapshot {
        let underlying: ScrollTargetWindowPolicy.Window
        let overlay: ScrollTargetWindowPolicy.Window
    }

    let underlying: NSWindow
    let overlay: NSWindow
    let ownerPID = ProcessInfo.processInfo.processIdentifier
    private let primaryTop: CGFloat
    private var closed = false

    // Native AppKit points. The base is 240×180; the overlay starts at local
    // (60,40) and is 120×100. Target is in the overlay's right half; the control
    // point is in its left half. Both are well inside the underlying window.
    var targetPoint: CGPoint {
        CGPoint(x: underlying.frame.minX + 150, y: underlying.frame.minY + 90)
    }
    var opaqueControlPoint: CGPoint {
        CGPoint(x: underlying.frame.minX + 90, y: underlying.frame.minY + 90)
    }

    init() throws {
        // Standalone hit-test probes can return zero before AppKit initializes.
        // Do not turn that setup failure into a product-policy failure.
        _ = NSApplication.shared
        NSApplication.shared.activate(ignoringOtherApps: true)
        let highestWindowLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        let screen = try XCTUnwrap(NSScreen.screens.first, "A native GUI screen is required")
        let visible = screen.visibleFrame
        _ = try XCTUnwrap(visible.width >= 320 && visible.height >= 260 ? screen : nil,
            "The two small owned windows must fit entirely on one visible display")
        primaryTop = screen.frame.maxY
        let frame = CGRect(x: visible.minX + 40, y: visible.minY + 40, width: 240, height: 180)
        underlying = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        overlay = NSWindow(contentRect: CGRect(x: frame.minX + 60, y: frame.minY + 40,
            width: 120, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        for window in [underlying, overlay] {
            window.isReleasedWhenClosed = false
            window.hasShadow = false
            window.hidesOnDeactivate = false
            window.level = highestWindowLevel
            window.alphaValue = 1
            window.ignoresMouseEvents = false
        }
        underlying.title = "SwiftShot Native Hit Test Target"
        underlying.backgroundColor = .white
        underlying.isOpaque = true
        underlying.contentView = NativeScrollHitPaintView(frame: CGRect(origin: .zero, size: frame.size),
            transparentRightHalf: false)
        overlay.title = "SwiftShot Native Hit Test Overlay"
    }

    func showUnderlyingWindow() async throws {
        underlying.makeKeyAndOrderFront(nil)
        underlying.orderFrontRegardless()
        underlying.displayIfNeeded()
        _ = try await waitForHit(at: targetPoint, expected: underlying.windowNumber)
    }

    func showOverlay(appearance: Appearance, ignoresMouseEvents: Bool) {
        let transparent = appearance == .transparentRightHalf
        overlay.isOpaque = !transparent
        overlay.backgroundColor = transparent ? .clear : .white
        overlay.ignoresMouseEvents = ignoresMouseEvents
        let paintView = NativeScrollHitPaintView(frame: CGRect(origin: .zero, size: overlay.frame.size),
            transparentRightHalf: transparent)
        if transparent { paintView.wantsLayer = true }
        overlay.contentView = paintView
        overlay.makeKey()
        overlay.orderFrontRegardless()
        overlay.contentView?.needsDisplay = true
        // A full owned-window draw establishes the clear area before hit tests;
        // native hit results, not this display call, still decide the outcome.
        overlay.display()
    }

    func verifyTransparentDrawingPreconditions() async throws {
        let view = try XCTUnwrap(overlay.contentView as? NativeScrollHitPaintView)
        for _ in 0..<100 {
            if view.drawCount > 0 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        _ = try XCTUnwrap(view.drawCount > 0 ? view : nil,
            "Transparency fixture has not executed its actual drawing code; this is a setup failure")
        XCTAssertFalse(overlay.isOpaque)
        XCTAssertFalse(view.isOpaque)
        XCTAssertEqual(overlay.backgroundColor.alphaComponent, 0)
        XCTAssertEqual(overlay.alphaValue, 1)
        XCTAssertFalse(overlay.ignoresMouseEvents)
        XCTAssertEqual(view.lastDrawnBounds, CGRect(x: 0, y: 0, width: 120, height: 100))
        XCTAssertEqual(view.lastClearedRect, CGRect(x: 60, y: 0, width: 60, height: 100))
        XCTAssertTrue(view.lastDirtyRect.contains(CGRect(x: 60, y: 0, width: 60, height: 100)),
            "The full clear half must be included in the real redraw, not clipped out by dirty-region optimization")

        // Render this actual owned view into AppKit's display-cache bitmap. This
        // establishes view-output alpha, not WindowServer composition or input
        // transparency; the unchanged native hit assertions still decide those.
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds),
            "The owned transparency fixture must provide an actual display-cache bitmap")
        view.cacheDisplay(in: view.bounds, to: bitmap)
        XCTAssertTrue(bitmap.hasAlpha, "The transparency diagnostic needs an alpha-bearing bitmap")
        _ = try XCTUnwrap(bitmap.pixelsWide >= 4 && bitmap.pixelsHigh >= 2 ? bitmap : nil,
            "The owned bitmap must contain both interior sample points")
        let opaqueLocal = view.convert(overlay.convertPoint(fromScreen: opaqueControlPoint), from: nil)
        let clearLocal = view.convert(overlay.convertPoint(fromScreen: targetPoint), from: nil)
        XCTAssertEqual(opaqueLocal, CGPoint(x: 30, y: 50))
        XCTAssertEqual(clearLocal, CGPoint(x: 90, y: 50))
        // Both native points lie on the vertical midpoint, so bitmap row
        // orientation cannot exchange the expected opaque and clear halves.
        let opaqueAlpha = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 4,
            y: bitmap.pixelsHigh / 2)).alphaComponent
        let clearAlpha = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide * 3 / 4,
            y: bitmap.pixelsHigh / 2)).alphaComponent
        XCTAssertEqual(opaqueAlpha, 1,
            "The actual cached left-point pixel must be fully opaque")
        XCTAssertEqual(clearAlpha, 0,
            "The actual cached right-point pixel must be fully transparent")

    }

    func quartz(_ nativePoint: CGPoint) -> CGPoint {
        CGPoint(x: nativePoint.x, y: primaryTop - nativePoint.y)
    }

    /// Polls only a read-only native hit test. This is bounded presentation
    /// settling, not a timing/performance target and not synthetic mouse input.
    func waitForHit(at point: CGPoint, expected: Int) async throws -> Int {
        _ = try XCTUnwrap(expected > 0 ? expected : nil, "The owned window must have a native ID")
        var hit = 0
        for _ in 0..<100 {
            hit = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
            if hit == expected { return hit }
            try await Task.sleep(for: .milliseconds(20))
        }
        let row = (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]])?
            .first { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == hit }
        // Attribute only the actual unexpected recipient. Never log its title,
        // image, other metadata, or unrelated inventory rows.
        let recipient = "pid=\(row?[kCGWindowOwnerPID as String] ?? "unknown"),level=\(row?[kCGWindowLayer as String] ?? "unknown"),bounds=\(row?[kCGWindowBounds as String] ?? "unknown")"
        return try XCTUnwrap(hit == expected ? hit : nil,
            "Native fixture did not establish expected hit window \(expected); actual \(hit) (\(recipient)). This is a setup/OS-boundary failure, not a passing policy test.")
    }

    /// Immediately filters public on-screen metadata to exactly two owned IDs,
    /// with no image/text capture or unrelated-window output. Neither expected
    /// identity nor geometry is obtained from production code.
    func snapshot() throws -> Snapshot {
        let baseID = try XCTUnwrap(CGWindowID(exactly: underlying.windowNumber))
        let overlayID = try XCTUnwrap(CGWindowID(exactly: overlay.windowNumber))
        XCTAssertNotEqual(baseID, 0)
        XCTAssertNotEqual(overlayID, 0)
        XCTAssertTrue(underlying.isVisible)
        XCTAssertTrue(overlay.isVisible)
        let ids: Set<CGWindowID> = [baseID, overlayID]
        let rows = try XCTUnwrap(CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID) as? [[String: Any]]).filter { value in
                guard let id = (value[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { return false }
                return ids.contains(id)
            }
        func row(for id: CGWindowID, window: NSWindow, size: CGSize) throws -> ScrollTargetWindowPolicy.Window {
            let matches = rows.filter { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id }
            XCTAssertEqual(matches.count, 1, "An exact owned native ID must resolve to one Quartz window")
            let value = try XCTUnwrap(matches.first)
            let pid = try XCTUnwrap((value[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value)
            XCTAssertEqual(pid, ownerPID)
            let raw = try XCTUnwrap(value[kCGWindowBounds as String] as? NSDictionary)
            let frame = try XCTUnwrap(CGRect(dictionaryRepresentation: raw))
            XCTAssertEqual(frame.size, size)
            XCTAssertEqual(frame, CGRect(x: window.frame.minX, y: primaryTop - window.frame.maxY,
                width: window.frame.width, height: window.frame.height),
                "Owned AppKit and Quartz window identity/coordinates must agree independently")
            let alpha = try XCTUnwrap((value[kCGWindowAlpha as String] as? NSNumber)?.doubleValue)
            return ScrollTargetWindowPolicy.Window(id: id, ownerPID: pid, frame: frame, alpha: alpha)
        }
        return try Snapshot(underlying: row(for: baseID, window: underlying, size: CGSize(width: 240, height: 180)),
            overlay: row(for: overlayID, window: overlay, size: CGSize(width: 120, height: 100)))
    }

    func close() {
        guard !closed else { return }
        closed = true
        for window in [overlay, underlying] {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
    }
}

@MainActor
private final class NativeScrollHitPaintView: NSView {
    private let transparentRightHalf: Bool
    override var isOpaque: Bool { !transparentRightHalf }
    private(set) var drawCount = 0
    private(set) var lastDrawnBounds = CGRect.zero
    private(set) var lastDirtyRect = CGRect.zero
    private(set) var lastClearedRect = CGRect.zero

    init(frame: CGRect, transparentRightHalf: Bool) {
        self.transparentRightHalf = transparentRightHalf
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.setBlendMode(.copy)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(bounds)
        let cleared = transparentRightHalf
            ? CGRect(x: bounds.midX, y: bounds.minY, width: bounds.width / 2, height: bounds.height)
            : .zero
        if transparentRightHalf { context.clear(cleared) }
        drawCount += 1
        lastDrawnBounds = bounds
        lastDirtyRect = dirtyRect
        lastClearedRect = cleared
    }
}
