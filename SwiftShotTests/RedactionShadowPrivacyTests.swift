import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import SwiftShot

private typealias ImageRenderer = SwiftShot.ImageRenderer

final class RedactionShadowPrivacyTests: XCTestCase {
    // Mutant caught: casting a shadow from source alpha before applying the
    // redaction lets hidden shapes affect otherwise public output pixels.
    func testNativePNGDoesNotRevealRedactedAlphaThroughShadow() async throws {
        try await assertShadowPrivacy(output: .native, width: 128, height: 108,
            redactedX: 24..<48, redactedY: 24..<64)
    }

    func testSmallerPNGDoesNotRevealRedactedAlphaThroughShadow() async throws {
        // 80×60 source + 24-pixel padding on every side = 128×108;
        // explicit 64-pixel smaller output is 64×54 at exactly half scale.
        try await assertShadowPrivacy(output: .smallerShare(maxPixelDimension: 64), width: 64, height: 54,
            redactedX: 12..<24, redactedY: 12..<32)
    }

    func testRoundedCroppedPNGDoesNotUseHiddenAlphaAtTheCornerForItsShadow() async throws {
        // Crop starts inside the redaction: intersection is x=1..<24/y=1..<40.
        // Native output is 40+48 on each axis, with a 23×39 black rectangle at
        // (24,24), including pixels outside the rounded source silhouette.
        try await assertShadowPrivacy(output: .native, width: 88, height: 88,
            redactedX: 24..<47, redactedY: 24..<63,
            crop: CGRect(x: 1, y: 1, width: 40, height: 40), cornerRadius: 12)
    }

    private func assertShadowPrivacy(output: RenderOutput, width: Int, height: Int,
                                     redactedX: Range<Int>, redactedY: Range<Int>,
                                     crop: CGRect = CGRect(x: 0, y: 0, width: 80, height: 60),
                                     cornerRadius: Double = 0) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftShotShadowPrivacy-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let background = directory.appendingPathComponent("white.png")
        try writeWhiteBackground(to: background)
        let sourceBytes = sources()
        XCTAssertGreaterThan(differentPixels(sourceBytes.first, sourceBytes.second, width: 80).count, 0)
        XCTAssertEqual(differentPixels(sourceBytes.first, sourceBytes.second, width: 80)
            .filter { !(0..<24).contains($0.x) || !(0..<40).contains($0.y) }.count, 0,
            "The two synthetic sources may differ only beneath the proposed redaction")
        let firstSource = try image(bytes: sourceBytes.first, width: 80, height: 60)
        let secondSource = try image(bytes: sourceBytes.second, width: 80, height: 60)
        let style = CaptureStyle(backgroundID: "synthetic-white", padding: 24, cornerRadius: cornerRadius, shadow: 18)
        let redaction = CaptureAnnotation(kind: .redact, start: .zero, end: CGPoint(x: 24, y: 40),
            color: AnnotationColor(red: 1, green: 0, blue: 0, alpha: 0))
        let renderer = ImageRenderer(cacheByteLimit: 0, cacheEntryLimit: 0)

        func request(_ source: CGImage, redacted: Bool) -> RenderRequest {
            RenderRequest(image: source,
                edits: CaptureEdits(crop: crop,
                    annotations: redacted ? [redaction] : [], style: style),
                backgroundURL: background, documentID: UUID(), output: output)
        }

        // Positive control: distinct hidden shapes must be observable without
        // redaction. Requiring a difference outside the proposed mask also
        // catches an implementation that "fixes" privacy by dropping shadows.
        let controlA = try decode(await renderer.render(request(firstSource, redacted: false)).png)
        let controlB = try decode(await renderer.render(request(secondSource, redacted: false)).png)
        let controlDifferences = differentPixels(controlA.bytes, controlB.bytes, width: controlA.width)
        XCTAssertGreaterThan(controlDifferences.count, 0, "The distinct input shapes must reach the PNG renderer")
        XCTAssertGreaterThan(controlDifferences.filter { !redactedX.contains($0.x) || !redactedY.contains($0.y) }.count, 0,
            "The control must exercise a real shadow extending beyond the proposed redaction")

        let protectedA = try decode(await renderer.render(request(firstSource, redacted: true)).png)
        let protectedB = try decode(await renderer.render(request(secondSource, redacted: true)).png)
        for result in [controlA, controlB, protectedA, protectedB] {
            XCTAssertEqual(result.width, width)
            XCTAssertEqual(result.height, height)
        }
        guard protectedA.width == width, protectedB.width == width,
              protectedA.height == height, protectedB.height == height else { return }

        // The final output itself must contain opaque black, regardless of the
        // annotation's deliberately transparent color and the source's alpha.
        for result in [protectedA, protectedB] {
            var nonOpaqueBlackPixels = 0
            for y in redactedY {
                for x in redactedX {
                    let offset = (y * width + x) * 4
                    if Array(result.bytes[offset..<offset + 4]) != [0, 0, 0, 255] { nonOpaqueBlackPixels += 1 }
                }
            }
            XCTAssertEqual(nonOpaqueBlackPixels, 0, "Every redaction pixel must remain opaque black after PNG encoding")
        }

        let differences = differentPixels(protectedA.bytes, protectedB.bytes, width: width)
        let outsideMask = differences.filter { !redactedX.contains($0.x) || !redactedY.contains($0.y) }
        // Count actual unequal RGBA pixels instead of dumping whole synthetic
        // images into a failing XCTest log. This compares the complete output.
        print("RedactionShadowPrivacy output=\(width)x\(height) differingPixels=\(differences.count) outsideRedaction=\(outsideMask.count) firstDifference=\(differences.first.map { "\($0.x),\($0.y)" } ?? "none")")
        XCTAssertEqual(differences.count, 0,
            "Changing only pixels hidden beneath an opaque redaction must not change ANY exported pixel, including shadow/padding")
    }

    private func sources() -> (first: [UInt8], second: [UInt8]) {
        var first = [UInt8](repeating: 0, count: 80 * 60 * 4)
        var second = first
        func fill(_ bytes: inout [UInt8], x: Range<Int>, y: Range<Int>, rgba: [UInt8]) {
            for row in y {
                for column in x {
                    let offset = (row * 80 + column) * 4
                    bytes.replaceSubrange(offset..<offset + 4, with: rgba)
                }
            }
        }
        // A shared visible witness ensures the image is not only hidden data.
        fill(&first, x: 60..<72, y: 42..<52, rgba: [0, 0, 255, 255])
        fill(&second, x: 60..<72, y: 42..<52, rgba: [0, 0, 255, 255])
        // Both shapes are wholly beneath x=0..<24, y=0..<40. Moving the alpha
        // silhouette toward the mask edge changes its unredacted shadow.
        fill(&first, x: 2..<7, y: 4..<35, rgba: [255, 0, 0, 255])
        fill(&second, x: 14..<22, y: 6..<36, rgba: [255, 0, 0, 255])
        return (first, second)
    }

    private func differentPixels(_ first: [UInt8], _ second: [UInt8], width: Int) -> [(x: Int, y: Int)] {
        guard first.count == second.count else {
            XCTFail("Pixel buffers have different lengths")
            return [(x: -1, y: -1)]
        }
        return stride(from: 0, to: first.count, by: 4).compactMap { offset in
            first[offset..<offset + 4] == second[offset..<offset + 4] ? nil : (x: offset / 4 % width, y: offset / 4 / width)
        }
    }

    private func image(bytes: [UInt8], width: Int, height: Int) throws -> CGImage {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func writeWhiteBackground(to url: URL) throws {
        let background = try image(bytes: [UInt8](repeating: 255, count: 2 * 2 * 4), width: 2, height: 2)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, background, nil)
        _ = try XCTUnwrap(CGImageDestinationFinalize(destination) ? true : nil, "Could not write the synthetic background")
    }

    private func decode(_ png: Data) throws -> (width: Int, height: Int, bytes: [UInt8]) {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: decoded.width, height: decoded.height, bitsPerComponent: 8,
            bytesPerRow: decoded.width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.interpolationQuality = .none
        context.draw(decoded, in: CGRect(x: 0, y: 0, width: decoded.width, height: decoded.height))
        let pixels = try XCTUnwrap(context.data?.assumingMemoryBound(to: UInt8.self))
        return (decoded.width, decoded.height,
            Array(UnsafeBufferPointer(start: pixels, count: context.bytesPerRow * decoded.height)))
    }
}
