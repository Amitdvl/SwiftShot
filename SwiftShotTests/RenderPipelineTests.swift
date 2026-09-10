import XCTest
import CoreGraphics
import ImageIO
import SwiftUI
@testable import SwiftShot

private typealias ImageRenderer = SwiftShot.ImageRenderer

final class RenderPipelineTests: XCTestCase {
    func testStyledCaptureKeepsTranslucentSourcePixelsOffTheDecorativeBackground() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftShotSourceBacking-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let background = directory.appendingPathComponent("blue.png")
        try writePNG(rgbaFixture(width: 2, height: 2, rgba: [0, 80, 255, 255]), to: background)
        // This models a transparent ScreenCaptureKit window corner / a
        // fractional-alpha type edge. Its visual backing must stay stable when
        // styling is toggled; the decorative image belongs only in the padding.
        let source = try rgbaFixture(width: 20, height: 20, rgba: [0, 0, 0, 0])
        let result = try await ImageRenderer().render(RenderRequest(image: source,
            edits: CaptureEdits(crop: CGRect(x: 0, y: 0, width: 20, height: 20),
                style: CaptureStyle(backgroundID: "blue", padding: 4, cornerRadius: 0, shadow: 0)), backgroundURL: background))
        let image = try decodePNG(result.png)
        XCTAssertEqual(try rgbaPixel(image, x: 10, y: 10), [255, 255, 255, 255],
            "The screenshot card must not inherit the decorative background through alpha")
        XCTAssertEqual(try rgbaPixel(image, x: 1, y: 1), [0, 80, 255, 255],
            "Padding remains the selected decorative background")
    }

    func testStyledShadowDoesNotPaintBlackBehindTransparentSource() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftShotAlpha-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let background = directory.appendingPathComponent("white.png")
        try writePNG(rgbaFixture(width: 2, height: 2, rgba: [255, 255, 255, 255]), to: background)
        let source = try rgbaFixture(width: 80, height: 80, rgba: [0, 0, 0, 0])
        let result = try await ImageRenderer().render(RenderRequest(image: source,
            edits: CaptureEdits(crop: CGRect(x: 0, y: 0, width: 80, height: 80),
                style: CaptureStyle(backgroundID: "white", padding: 12, cornerRadius: 4, shadow: 6)), backgroundURL: background))
        let decoded = try decodePNG(result.png)
        XCTAssertEqual(try rgbaPixel(decoded, x: 52, y: 52), [255, 255, 255, 255],
            "A fully transparent image must not acquire a black interior from the shadow silhouette")
    }

    func testStyledShadowPreservesTranslucentSourceOverBackground() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftShotAlpha-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let background = directory.appendingPathComponent("white.png")
        try writePNG(rgbaFixture(width: 2, height: 2, rgba: [255, 255, 255, 255]), to: background)
        let source = try rgbaFixture(width: 80, height: 80, rgba: [128, 0, 0, 128])
        let result = try await ImageRenderer().render(RenderRequest(image: source,
            edits: CaptureEdits(crop: CGRect(x: 0, y: 0, width: 80, height: 80),
                style: CaptureStyle(backgroundID: "white", padding: 12, cornerRadius: 4, shadow: 6)), backgroundURL: background))
        let pixel = try rgbaPixel(decodePNG(result.png), x: 52, y: 52)
        // A 35%-maximum shadow may darken the white beneath 50%-alpha red,
        // but cannot replace it with an opaque black matte (old output 128,0,0).
        XCTAssertGreaterThan(pixel[0], 191)
        XCTAssertGreaterThan(pixel[1], 63)
        XCTAssertGreaterThan(pixel[2], 63)
        XCTAssertEqual(pixel[3], 255)
    }

    @MainActor func testTransparentBackgroundPreviewUsesSameWhiteBackingAsPNG() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftShotPreviewAlpha-\(UUID())")
        let bundle = directory.appendingPathComponent("backgrounds")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let background = bundle.appendingPathComponent("transparent.png")
        try writePNG(rgbaFixture(width: 2, height: 2, rgba: [0, 0, 0, 0]), to: background)
        let library = BackgroundLibrary(rootURL: directory.appendingPathComponent("library"), bundleURL: bundle)
        let id = "bundled:transparent"
        var ready = false
        for _ in 0..<100 {
            if library.thumbnail(for: id) != nil { ready = true; break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(ready, "Real background thumbnail did not finish decoding")
        guard ready else { return }
        let source = try rgbaFixture(width: 20, height: 20, rgba: [0, 0, 255, 255])
        let style = CaptureStyle(backgroundID: id, padding: 4, cornerRadius: 0, shadow: 0)
        let screen = FrozenScreen(id: 1, frame: CGRect(x: 0, y: 0, width: 640, height: 480), image: source, windows: [])
        let session = OverlaySession(mode: .region, style: style, library: library,
            onDocument: { _ in }, onCopy: { _ in }, onSave: { _ in }, onOCR: { _ in }, onCancel: {})
        session.document = CaptureDocument(image: source, style: style)
        session.activeScreenID = 1
        // SwiftUI's software renderer creates no NSWindow and never orders UI onscreen.
        let previewRenderer = SwiftUI.ImageRenderer(content: CaptureOverlayView(screen: screen, session: session))
        previewRenderer.scale = 1
        let preview = try XCTUnwrap(previewRenderer.cgImage)
        XCTAssertEqual(preview.width, 640)
        XCTAssertEqual(preview.height, 480)
        // The 370×370 styled canvas starts at (135,55); this sample lies in its
        // left padding, away from the screenshot, toolbar and annotation chrome.
        let previewPixel = try rgbaPixel(preview, x: 145, y: 240)
        let exported = try await ImageRenderer().render(RenderRequest(image: source,
            edits: CaptureEdits(crop: CGRect(x: 0, y: 0, width: 20, height: 20), style: style), backgroundURL: background))
        XCTAssertEqual(try rgbaPixel(decodePNG(exported.png), x: 1, y: 14), [255, 255, 255, 255])
        XCTAssertEqual(previewPixel, [255, 255, 255, 255], "Preview showed the dimmed desktop through transparent padding")
    }

    private func rgbaFixture(width: Int, height: Int, rgba: [UInt8]) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let bytes = try XCTUnwrap(context.data?.assumingMemoryBound(to: UInt8.self))
        for index in 0..<(width * height * 4) { bytes[index] = rgba[index % 4] }
        return try XCTUnwrap(context.makeImage())
    }

    private func rgbaPixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try XCTUnwrap(context.data?.assumingMemoryBound(to: UInt8.self))
        return Array(UnsafeBufferPointer(start: bytes + y * context.bytesPerRow + x * 4, count: 4))
    }

    private func writePNG(_ image: CGImage, to url: URL) throws {
        let encoder = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(encoder, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(encoder))
    }

    private func decodePNG(_ data: Data) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    // Removing source admission from the raw fast path must fail before any encode.
    func testRawBitmapRefusesSourceAboveWorkingSetBudget() async throws {
        let renderer = ImageRenderer(workingSetByteLimit: 1)
        do {
            _ = try await renderer.renderImage(RenderRequest(image: fixture(),
                edits: CaptureEdits(crop: CGRect(x: 0, y: 0, width: 80, height: 40)), backgroundURL: nil))
            XCTFail("Raw bitmap bypassed source-byte admission")
        } catch ImageRenderer.RenderError.imageTooLarge { }
        catch { XCTFail("Unexpected error: \(error)") }
        let statistics = await renderer.cacheStatistics
        XCTAssertEqual(statistics.renders, 0)
        XCTAssertEqual(statistics.encodes, 0)
    }

    // A bitmap can be safe to return zero-copy while its PNG workspace is not.
    func testRawPNGRefusesEncodingWorkspaceButBitmapStaysZeroCopy() async throws {
        let image = fixture()
        let bytes = image.bytesPerRow * image.height
        let renderer = ImageRenderer(workingSetByteLimit: 64 * 1024 * 1024 + bytes * 2)
        let request = RenderRequest(image: image,
            edits: CaptureEdits(crop: CGRect(x: 0, y: 0, width: 80, height: 40)), backgroundURL: nil)
        let bitmap = try await renderer.renderImage(request)
        XCTAssertTrue(bitmap === image)
        do {
            _ = try await renderer.render(request)
            XCTFail("Raw PNG bypassed source + encode workspace admission")
        } catch ImageRenderer.RenderError.imageTooLarge { }
        catch { XCTFail("Unexpected error: \(error)") }
        let statistics = await renderer.cacheStatistics
        XCTAssertEqual(statistics.encodes, 0)
    }

    func testWorkingSetSourceArithmeticRejectsOverflowAndInvalidBytes() throws {
        let policy = ImageRenderer.WorkingSetBudget()
        XCTAssertEqual(try policy.admitSource(bytesPerRow: 320, height: 40), 12_800)
        XCTAssertEqual(try policy.admitSource(bytesPerRow: 512 * 1024 * 1024, height: 1), 536_870_912)
        for (row, height) in [(Int.max, 2), (512 * 1024 * 1024, 2), (0, 10), (10, 0), (-1, 10)] {
            XCTAssertThrowsError(try policy.admitSource(bytesPerRow: row, height: height)) { error in
                guard case ImageRenderer.RenderError.imageTooLarge = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }
    }

    func testPNGWorkingSetChargesDistinctOutputAndRejectsOverflow() throws {
        let policy = ImageRenderer.WorkingSetBudget(byteLimit: 64 * 1024 * 1024 + 300)
        XCTAssertNoThrow(try policy.admitPNG(sourceBytes: 100, outputBytes: 100, sharesSource: true))
        XCTAssertThrowsError(try policy.admitPNG(sourceBytes: 101, outputBytes: 100, sharesSource: true))
        XCTAssertThrowsError(try policy.admitPNG(sourceBytes: 100, outputBytes: 100, sharesSource: false))
        XCTAssertThrowsError(try policy.admitPNG(sourceBytes: Int.max, outputBytes: 100, sharesSource: true))
        XCTAssertThrowsError(try policy.admitPNG(sourceBytes: 100, outputBytes: Int.max, sharesSource: false))
        XCTAssertThrowsError(try policy.admitPNG(sourceBytes: -1, outputBytes: 100, sharesSource: true))
    }

    func testPNGWorkingSetAcceptsOrdinary4KButRejectsLargeHighBitDepth() throws {
        let policy = ImageRenderer.WorkingSetBudget()
        // Literal row-byte totals: 3840×2160×4 and 8000×8000×8/16.
        XCTAssertNoThrow(try policy.admitPNG(sourceBytes: 33_177_600, outputBytes: 33_177_600, sharesSource: false))
        XCTAssertThrowsError(try policy.admitPNG(sourceBytes: 512_000_000, outputBytes: 512_000_000, sharesSource: true))
        XCTAssertThrowsError(try policy.admitPNG(sourceBytes: 1_024_000_000, outputBytes: 512_000_000, sharesSource: false))
    }

    private func fixture(width: Int = 80, height: Int = 40,
                         space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!,
                         bits: Int = 8) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: bits,
                                bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 0.5))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    // Regression: a raw full capture must not allocate a second bitmap or convert
    // its color space/bit depth on the hot Copy/OCR path.
    func testRawFullImageKeepsImmutableSourceInsteadOfRecompositing() async throws {
        let source = fixture(space: CGColorSpace(name: CGColorSpace.displayP3)!)
        let result = try await ImageRenderer().render(RenderRequest(image: source,
            edits: CaptureEdits(crop: CGRect(x: 0, y: 0, width: 80, height: 40)), backgroundURL: nil))
        XCTAssertTrue(result.image === source, "Raw export unnecessarily allocated/recomposited the source")
        XCTAssertEqual(result.image.colorSpace?.name, CGColorSpace.displayP3)
    }

    func testBitmapOnlyDoesNotEncodeAndEncodedResultIsReused() async throws {
        let renderer = ImageRenderer()
        let request = RenderRequest(image: fixture(), edits: CaptureEdits(crop: CGRect(x: 0, y: 0, width: 80, height: 40)), backgroundURL: nil)
        let image = try await renderer.renderImage(request)
        let initial = await renderer.cacheStatistics
        XCTAssertEqual(initial.encodes, 0)
        let first = try await renderer.render(request)
        let second = try await renderer.render(request)
        XCTAssertTrue(first.image === image)
        XCTAssertTrue(second.image === first.image)
        XCTAssertEqual(first.png, second.png)
        let final = await renderer.cacheStatistics
        XCTAssertEqual(final.renders, 1)
        XCTAssertEqual(final.encodes, 1)
    }

    func testProtocolDispatchSkipsPNGAndClearsCache() async throws {
        let renderer = ImageRenderer()
        let provider: any CaptureRendering = renderer
        _ = try await provider.renderImage(RenderRequest(image: fixture(),
            edits: CaptureEdits(crop: CGRect(x: 0, y: 0, width: 80, height: 40)), backgroundURL: nil))
        var stats = await renderer.cacheStatistics
        XCTAssertEqual(stats.encodes, 0)
        XCTAssertEqual(stats.entries, 1)
        await provider.clearCache()
        stats = await renderer.cacheStatistics
        XCTAssertEqual(stats.entries, 0)
        XCTAssertEqual(stats.retainedBytes, 0)
    }

    func testChangedEditsCannotHitCacheEvenIfCallerReusesRevision() async throws {
        let renderer = ImageRenderer()
        let image = fixture()
        let id = UUID()
        let first = try await renderer.render(RenderRequest(image: image, edits: CaptureEdits(crop: CGRect(x: 0, y: 0, width: 80, height: 40)), backgroundURL: nil, documentID: id))
        let next = try await renderer.render(RenderRequest(image: image, edits: CaptureEdits(crop: CGRect(x: 0, y: 0, width: 40, height: 20)), backgroundURL: nil, documentID: id))
        XCTAssertEqual(first.image.width, 80)
        XCTAssertEqual(next.image.width, 40)
    }

    func testSmallShareFitsLongestAxisAndNeverUpscales() async throws {
        let renderer = ImageRenderer()
        let image = fixture()
        for (limit, width, height) in [(20, 20, 10), (160, 80, 40)] {
            let result = try await renderer.renderImage(RenderRequest(image: image,
                edits: CaptureEdits(crop: CGRect(x: 0, y: 0, width: 80, height: 40)), backgroundURL: nil,
                output: .smallerShare(maxPixelDimension: limit)))
            XCTAssertEqual(result.width, width)
            XCTAssertEqual(result.height, height)
        }
    }

    func testCacheBudgetAndClearReleaseRetainedEntries() async throws {
        let renderer = ImageRenderer(cacheByteLimit: 30_000, cacheEntryLimit: 2)
        for _ in 0..<8 {
            _ = try await renderer.render(RenderRequest(image: fixture(), edits: CaptureEdits(crop: CGRect(x: 0, y: 0, width: 80, height: 40)), backgroundURL: nil))
            let stats = await renderer.cacheStatistics
            XCTAssertLessThanOrEqual(stats.retainedBytes, 30_000)
            XCTAssertLessThanOrEqual(stats.entries, 2)
        }
        await renderer.clearCache()
        let stats = await renderer.cacheStatistics
        XCTAssertEqual(stats.retainedBytes, 0)
        XCTAssertEqual(stats.entries, 0)
    }

    func testNewAnnotationKindsChangePixels() async throws {
        let source = fixture()
        let renderer = ImageRenderer()
        let raw = try await renderer.render(RenderRequest(image: source, edits: CaptureEdits(crop: CGRect(x: 0, y: 0, width: 80, height: 40)), backgroundURL: nil))
        for kind in [CaptureAnnotation.Kind.highlighter, .numberedStep, .spotlight] {
            let annotation = CaptureAnnotation(kind: kind, start: CGPoint(x: 20, y: 10), end: CGPoint(x: 60, y: 30), text: "2", fontSize: 16)
            let result = try await renderer.render(RenderRequest(image: source,
                edits: CaptureEdits(crop: CGRect(x: 0, y: 0, width: 80, height: 40), annotations: [annotation]), backgroundURL: nil))
            XCTAssertNotEqual(result.png, raw.png, "Missing \(kind) pixels")
        }
    }

    @MainActor func testAnnotationTransformsAreUndoableAndPreserveArrowDirection() throws {
        let annotation = CaptureAnnotation(kind: .arrow, start: CGPoint(x: 60, y: 30), end: CGPoint(x: 20, y: 10))
        let moved = annotation.translated(by: CGSize(width: 3, height: -2))
        XCTAssertEqual(moved.start, CGPoint(x: 63, y: 28))
        XCTAssertEqual(moved.end, CGPoint(x: 23, y: 8))
        let resized = annotation.resized(to: CGRect(x: 10, y: 5, width: 20, height: 10))
        XCTAssertEqual(resized.start, CGPoint(x: 30, y: 15))
        XCTAssertEqual(resized.end, CGPoint(x: 10, y: 5))
        let document = CaptureDocument(image: fixture(), edits: CaptureEdits(crop: CGRect(x: 0, y: 0, width: 80, height: 40), annotations: [annotation]))
        document.updateAnnotation(id: annotation.id) { $0 = moved }
        XCTAssertEqual(document.edits.annotations[0], moved)
        document.undo()
        XCTAssertEqual(document.edits.annotations[0], annotation)
        document.removeAnnotation(id: annotation.id)
        XCTAssertTrue(document.edits.annotations.isEmpty)
        document.undo()
        XCTAssertEqual(document.edits.annotations, [annotation])
    }

    func testArrowHitTestingDoesNotSelectEmptyBoundingBoxCorners() {
        let annotation = CaptureAnnotation(kind: .arrow, start: .zero, end: CGPoint(x: 100, y: 100), lineWidth: 4)
        XCTAssertTrue(AnnotationGeometry.hitTest(CGPoint(x: 50, y: 51), annotation: annotation, tolerance: 2))
        XCTAssertFalse(AnnotationGeometry.hitTest(CGPoint(x: 0, y: 100), annotation: annotation, tolerance: 2))
    }

    func testLegacyAnnotationJSONStillDecodes() throws {
        // Frozen pre-extension format: no step-specific or geometry-version keys.
        let data = Data(#"{"id":"AA000000-0000-0000-0000-000000000001","kind":"text","start":[10,8],"end":[0,0],"text":"one\ntwo","color":{"red":1,"green":0.27,"blue":0.24,"alpha":1},"lineWidth":6,"fontSize":32}"#.utf8)
        let annotation = try JSONDecoder().decode(CaptureAnnotation.self, from: data)
        XCTAssertEqual(annotation.kind, .text)
        XCTAssertEqual(annotation.start, CGPoint(x: 10, y: 8))
        XCTAssertEqual(annotation.text, "one\ntwo")
        XCTAssertEqual(annotation.fontSize, 32)
    }

    func testMultilineTextLayoutUsesNativePixelFontMetrics() {
        let layout = AnnotationTextLayout(text: "one\ntwo", fontSize: 20, color: AnnotationColor())
        XCTAssertEqual(layout.lines.count, 2)
        XCTAssertEqual(layout.lineHeight, 24)
        XCTAssertGreaterThan(layout.size.width, 20)
    }

    func testDownscaledRedactionEdgesRemainOpaqueAfterResampling() async throws {
        let annotation = CaptureAnnotation(kind: .redact, start: CGPoint(x: 7, y: 5), end: CGPoint(x: 33, y: 19))
        let result = try await ImageRenderer().renderImage(RenderRequest(image: fixture(),
            edits: CaptureEdits(crop: CGRect(x: 0, y: 0, width: 80, height: 40), annotations: [annotation]),
            backgroundURL: nil, output: .smallerShare(maxPixelDimension: 20)))
        let context = CGContext(data: nil, width: 20, height: 10, bitsPerComponent: 8, bytesPerRow: 80,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(result, in: CGRect(x: 0, y: 0, width: 20, height: 10))
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        // Native x=7...33, y=5...19 covers output x=1...8, y=1...4.
        for y in 1..<5 {
            for x in 1..<9 {
                let offset = (y * 20 + x) * 4
                XCTAssertEqual(Array(UnsafeBufferPointer(start: pixels + offset, count: 4)), [0, 0, 0, 255])
            }
        }
    }

    func testEditedDisplayP3KeepsTaggedColorAndUntouchedTransparency() async throws {
        let source = fixture(space: CGColorSpace(name: CGColorSpace.displayP3)!)
        let annotation = CaptureAnnotation(kind: .redact, start: .zero, end: CGPoint(x: 5, y: 5))
        let result = try await ImageRenderer().render(RenderRequest(image: source,
            edits: CaptureEdits(crop: CGRect(x: 0, y: 0, width: 80, height: 40), annotations: [annotation]), backgroundURL: nil))
        XCTAssertEqual(result.image.colorSpace?.name, CGColorSpace.displayP3)
        let decoder = try XCTUnwrap(CGImageSourceCreateWithData(result.png as CFData, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(decoder, 0, nil))
        XCTAssertEqual(decoded.colorSpace?.name, CGColorSpace.displayP3)
        let alpha = result.image.dataProvider!.data! as Data
        XCTAssertEqual(alpha[20 * result.image.bytesPerRow + 40 * 4 + 3], 128)
    }

    func testOverlappingSpotlightsLeaveUnionUndimmed() async throws {
        let source = fixture()
        let annotations = [
            CaptureAnnotation(kind: .spotlight, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 40, y: 30)),
            CaptureAnnotation(kind: .spotlight, start: CGPoint(x: 30, y: 10), end: CGPoint(x: 60, y: 30))
        ]
        let result = try await ImageRenderer().renderImage(RenderRequest(image: source,
            edits: CaptureEdits(crop: CGRect(x: 0, y: 0, width: 80, height: 40), annotations: annotations), backgroundURL: nil))
        let original = source.dataProvider!.data! as Data
        let output = result.dataProvider!.data! as Data
        for x in [20, 35, 50] {
            let src = 20 * source.bytesPerRow + x * 4
            let dst = 20 * result.bytesPerRow + x * 4
            XCTAssertEqual(output[dst..<dst + 4], original[src..<src + 4])
        }
        XCTAssertNotEqual(output[0..<4], original[0..<4])
    }

    func testSixteenBitSourceKeepsPrecisionThroughAnnotationsAndPNG() async throws {
        let source = fixture(bits: 16)
        let annotation = CaptureAnnotation(kind: .rectangle, start: CGPoint(x: 4, y: 4), end: CGPoint(x: 30, y: 20))
        let result = try await ImageRenderer().render(RenderRequest(image: source,
            edits: CaptureEdits(crop: CGRect(x: 0, y: 0, width: 80, height: 40), annotations: [annotation]), backgroundURL: nil))
        XCTAssertEqual(result.image.bitsPerComponent, 16)
        let decoder = try XCTUnwrap(CGImageSourceCreateWithData(result.png as CFData, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(decoder, 0, nil))
        XCTAssertEqual(decoded.bitsPerComponent, 16)
    }

    func testReplacingBackgroundInvalidatesSameDocumentRevision() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("swiftshot-render-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        func write(_ image: CGImage, modified: TimeInterval) throws {
            let encoder = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(encoder, image, nil)
            XCTAssertTrue(CGImageDestinationFinalize(encoder))
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: modified)], ofItemAtPath: url.path)
        }
        try write(fixture(), modified: 1000)
        let source = fixture()
        let request = RenderRequest(image: source,
            edits: CaptureEdits(crop: CGRect(x: 0, y: 0, width: 80, height: 40),
                style: CaptureStyle(backgroundID: "custom", padding: 4, cornerRadius: 0, shadow: 0)),
            backgroundURL: url, documentID: UUID())
        let renderer = ImageRenderer()
        _ = try await renderer.render(request)
        try write(fixture(width: 3, height: 3), modified: 2000)
        _ = try await renderer.render(request)
        var statistics = await renderer.cacheStatistics
        XCTAssertEqual(statistics.renders, 2)
        var newVersion = request
        newVersion.backgroundVersion = 1
        _ = try await renderer.render(newVersion)
        statistics = await renderer.cacheStatistics
        XCTAssertEqual(statistics.renders, 3)
    }

    func testInvalidShareDimensionIsRejectedInsteadOfAllocating() async {
        for limit in [0, -1, 32_769, Int.max] {
            do {
                _ = try await ImageRenderer().renderImage(RenderRequest(image: fixture(),
                    edits: CaptureEdits(crop: CGRect(x: 0, y: 0, width: 80, height: 40)), backgroundURL: nil,
                    output: .smallerShare(maxPixelDimension: limit)))
                XCTFail("Invalid output limit \(limit) accepted")
            } catch ImageRenderer.RenderError.invalidGeometry { }
            catch { XCTFail("Unexpected error: \(error)") }
        }
    }

    func testAggregateAnnotationTextIsRejectedBeforeTextLayoutAllocation() async {
        // Every individual annotation is within the existing 100 KB allowance;
        // only the aggregate payload exceeds the render session's text budget.
        let text = String(repeating: "a", count: 100_000)
        let annotations = (0..<11).map { _ in
            CaptureAnnotation(kind: .text, start: .zero, end: .zero, text: text)
        }
        do {
            _ = try await ImageRenderer().renderImage(RenderRequest(image: fixture(),
                edits: CaptureEdits(crop: CGRect(x: 0, y: 0, width: 80, height: 40), annotations: annotations), backgroundURL: nil))
            XCTFail("Aggregate annotation payload was not bounded before CoreText allocation")
        } catch ImageRenderer.RenderError.invalidGeometry { }
        catch { XCTFail("Unexpected error: \(error)") }
    }

    func testCacheBudgetChargesRetainedAnnotationMetadata() async throws {
        let annotation = CaptureAnnotation(kind: .rectangle, start: .zero, end: CGPoint(x: 20, y: 20),
            text: String(repeating: "a", count: 4_000))
        let renderer = ImageRenderer(cacheByteLimit: 30_000)
        _ = try await renderer.renderImage(RenderRequest(image: fixture(),
            edits: CaptureEdits(crop: CGRect(x: 0, y: 0, width: 80, height: 40), annotations: [annotation]), backgroundURL: nil))
        let stats = await renderer.cacheStatistics
        XCTAssertEqual(stats.entries, 0, "Source + output + annotation text must exceed this 30 KB budget")
        XCTAssertEqual(stats.retainedBytes, 0)
    }

    func testUnicodeNewlineFloodIsRejectedBeforeCoreTextAllocation() async {
        let annotation = CaptureAnnotation(kind: .text, start: .zero, end: .zero,
            text: String(repeating: "\u{2028}", count: 17_000))
        do {
            _ = try await ImageRenderer().renderImage(RenderRequest(image: fixture(),
                edits: CaptureEdits(crop: CGRect(x: 0, y: 0, width: 80, height: 40), annotations: [annotation]), backgroundURL: nil))
            XCTFail("Unicode newline count was not bounded")
        } catch ImageRenderer.RenderError.invalidGeometry { }
        catch { XCTFail("Unexpected error: \(error)") }
    }
}
