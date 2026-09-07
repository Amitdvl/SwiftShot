import XCTest
import AppKit
import SwiftUI
import CoreText
@testable import SwiftShot

@MainActor
final class RenderingEvidenceTests: XCTestCase {
    func testLargeNativeRenderAllowsMainActorProgress() async throws {
        let image = try card(width: 3840, height: 2160)
        let request = RenderRequest(image: image, edits: CaptureEdits(crop: CGRect(x: 0, y: 0, width: 3840, height: 2160)), backgroundURL: nil)
        let renderer = SwiftShot.ImageRenderer()
        var finished = false
        let start = ContinuousClock.now
        let rendering = Task {
            defer { finished = true }
            return try await renderer.render(request)
        }
        var beats = 0
        var largestGap: Duration = .zero
        var previous = ContinuousClock.now
        while !finished {
            try await Task.sleep(for: .milliseconds(5))
            let now = ContinuousClock.now
            largestGap = max(largestGap, previous.duration(to: now))
            previous = now
            beats += 1
        }
        let result = try await rendering.value
        XCTAssertEqual(result.image.width, 3840)
        XCTAssertEqual(result.image.height, 2160)
        XCTAssertGreaterThan(beats, 1, "Main actor should keep servicing input while the 4K export renders")
        print("RENDER_METRIC 3840x2160 elapsed=\(start.duration(to: .now)) mainActorBeats=\(beats) largestGap=\(largestGap)")
    }

    func testGenerateOverlayVisualEvidence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftShot-VisualEvidence-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let library = BackgroundLibrary(rootURL: root.appendingPathComponent("library"))
        let image = try card(width: 1920, height: 1200)
        let screen = FrozenScreen(id: 1, frame: CGRect(x: 0, y: 0, width: 1280, height: 800), image: image, windows: [])
        let session = OverlaySession(mode: .region, style: CaptureStyle(), library: library,
            onDocument: { _ in }, onCopy: { _ in }, onSave: { _ in }, onOCR: { _ in }, onCancel: {})
        session.select(screen: screen, crop: CGRect(x: 240, y: 200, width: 1280, height: 760))
        let document = try XCTUnwrap(session.document)
        document.change {
            $0.annotations.append(CaptureAnnotation(kind: .arrow, start: CGPoint(x: 980, y: 670), end: CGPoint(x: 760, y: 490), lineWidth: 8))
        }
        for dark in [false, true] {
            for panel in ["toolbar", "backgrounds", "annotations"] {
                session.activePopover = panel == "backgrounds" ? .backgrounds : (panel == "annotations" ? .annotations : nil)
                if panel == "backgrounds" {
                    document.change { $0.style.backgroundID = "bundled:blue" }
                    _ = library.thumbnail(for: "bundled:blue")
                }
                let hosting = NSHostingView(rootView: CaptureOverlayView(screen: screen, session: session).environment(\.colorScheme, dark ? .dark : .light))
                let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 1280, height: 800), styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = hosting
                window.orderFrontRegardless()
                try await Task.sleep(for: .milliseconds(700))
                hosting.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                let path = root.appendingPathComponent("\(dark ? "dark" : "light")-\(panel).png")
                try png.write(to: path)
                window.close()
                XCTAssertGreaterThan(png.count, 1000)
                print("VISUAL_ARTIFACT \(path.path)")
            }
        }
    }

    private func card(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let scale = CGFloat(width) / 1920
        context.scaleBy(x: scale, y: scale)
        let h = CGFloat(height) / scale
        context.setFillColor(CGColor(red: 0.91, green: 0.94, blue: 0.97, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1920, height: h))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.addPath(CGPath(roundedRect: CGRect(x: 240, y: h - 960, width: 1280, height: 760), cornerWidth: 20, cornerHeight: 20, transform: nil))
        context.fillPath()
        func label(_ text: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, _ gray: CGFloat) {
            let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: gray, alpha: 1)
            ]))
            context.textPosition = CGPoint(x: x, y: h - y)
            CTLineDraw(line, context)
        }
        label("FIELD NOTES", 310, 310, 21, 0.45)
        label("Make room for better work.", 310, 410, 48, 0.12)
        label("A clear idea. A simple next step. A little less noise.", 310, 470, 25, 0.35)
        context.setFillColor(CGColor(red: 0.15, green: 0.35, blue: 0.88, alpha: 1))
        context.addPath(CGPath(roundedRect: CGRect(x: 310, y: h - 610, width: 215, height: 60), cornerWidth: 12, cornerHeight: 12, transform: nil))
        context.fillPath()
        label("Start something", 335, 589, 21, 1)
        label("01   Create something useful", 310, 730, 23, 0.22)
        label("02   Keep the details sharp", 310, 790, 23, 0.22)
        label("03   Get back to your day", 310, 850, 23, 0.22)
        return try XCTUnwrap(context.makeImage())
    }
}
