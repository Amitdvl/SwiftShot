import XCTest
import CoreGraphics
import ImageIO
@testable import SwiftShot

final class ImageRendererTests: XCTestCase {
    private func fixture(width: Int = 47, height: Int = 29) -> CGImage {
        var bytes = [UInt8]()
        for y in 0..<height {
            for x in 0..<width {
                bytes += [UInt8((x * 17) % 256), UInt8((y * 29) % 256), UInt8((x + y) % 256), 255]
            }
        }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)!
    }

    private func pixels(_ image: CGImage) -> [UInt8] {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }

    private func pixel(_ data: [UInt8], width: Int, x: Int, y: Int) -> [UInt8] {
        Array(data[(y * width + x) * 4..<(y * width + x + 1) * 4])
    }

    private func backgroundFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, fixture(width: 2, height: 2), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    func testUnframedImagePreservesEveryPixelAndIgnoresDecorativePadding() async throws {
        let source = fixture()
        let result = try await ImageRenderer().render(RenderRequest(image: source,
            edits: CaptureEdits(crop: CGRect(x: 0, y: 0, width: 47, height: 29),
                                style: CaptureStyle(padding: 72, cornerRadius: 20, shadow: 24)), backgroundURL: nil))
        XCTAssertEqual(result.image.width, 47)
        XCTAssertEqual(result.image.height, 29)
        XCTAssertEqual(pixels(result.image), pixels(source))
        let decoded = CGImageSourceCreateWithData(result.png as CFData, nil)!
        XCTAssertEqual(pixels(CGImageSourceCreateImageAtIndex(decoded, 0, nil)!), pixels(source))
    }

    func testFramedNonSquarePixelsRemainNativeSizeAtIntegerOffset() async throws {
        let url = try backgroundFile()
        defer { try? FileManager.default.removeItem(at: url) }
        for (width, height) in [(47, 29), (29, 47), (94, 58)] {
            let source = fixture(width: width, height: height)
            let result = try await ImageRenderer().render(RenderRequest(image: source,
                edits: CaptureEdits(crop: CGRect(x: 0, y: 0, width: width, height: height),
                                    style: CaptureStyle(backgroundID: "custom", padding: 7, cornerRadius: 0, shadow: 0)), backgroundURL: url))
            XCTAssertEqual(result.image.width, width + 14)
            XCTAssertEqual(result.image.height, height + 14)
            let output = pixels(result.image)
            let input = pixels(source)
            for y in 0..<height {
                for x in 0..<width {
                    XCTAssertEqual(pixel(output, width: width + 14, x: x + 7, y: y + 7),
                                   pixel(input, width: width, x: x, y: y))
                }
            }
        }
    }

    func testFramedPaddingIsCappedWithoutResamplingTheCapture() async throws {
        let url = try backgroundFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let source = fixture(width: 2936, height: 1630)
        let style = CaptureStyle(backgroundID: "custom", padding: 240, cornerRadius: 0, shadow: 0)
        let result = try await ImageRenderer().render(RenderRequest(image: source,
            edits: CaptureEdits(crop: CGRect(x: 0, y: 0, width: source.width, height: source.height), style: style),
            backgroundURL: url))

        XCTAssertEqual(style.effectivePadding, CaptureStyle.maxEffectivePadding)
        XCTAssertEqual(result.image.width, source.width + CaptureStyle.maxEffectivePadding * 2)
        XCTAssertEqual(result.image.height, source.height + CaptureStyle.maxEffectivePadding * 2)
        let output = pixels(result.image)
        let input = pixels(source)
        XCTAssertEqual(pixel(output, width: result.image.width,
                             x: CaptureStyle.maxEffectivePadding + 100,
                             y: CaptureStyle.maxEffectivePadding + 100),
                       pixel(input, width: source.width, x: 100, y: 100))
    }

    func testCropUsesTopLeftCoordinates() async throws {
        let source = fixture()
        let result = try await ImageRenderer().render(RenderRequest(image: source,
            edits: CaptureEdits(crop: CGRect(x: 5, y: 3, width: 17, height: 11)), backgroundURL: nil))
        XCTAssertEqual(result.image.width, 17)
        XCTAssertEqual(result.image.height, 11)
        let output = pixels(result.image)
        let input = pixels(source)
        for y in 0..<11 {
            for x in 0..<17 {
                XCTAssertEqual(pixel(output, width: 17, x: x, y: y), pixel(input, width: 47, x: x + 5, y: y + 3))
            }
        }
    }

    func testRedactionIsOpaqueFlattenedAndAppliedAfterOtherAnnotations() async throws {
        let source = fixture()
        let redaction = CaptureAnnotation(kind: .redact, start: CGPoint(x: 8, y: 5), end: CGPoint(x: 17, y: 10),
                                          color: AnnotationColor(red: 1, green: 0, blue: 0, alpha: 0))
        let rectangle = CaptureAnnotation(kind: .rectangle, start: CGPoint(x: 8, y: 5), end: CGPoint(x: 17, y: 10), lineWidth: 5)
        let result = try await ImageRenderer().render(RenderRequest(image: source,
            edits: CaptureEdits(crop: CGRect(x: 5, y: 3, width: 25, height: 20), annotations: [redaction, rectangle]), backgroundURL: nil))
        let pngSource = CGImageSourceCreateWithData(result.png as CFData, nil)!
        let output = pixels(CGImageSourceCreateImageAtIndex(pngSource, 0, nil)!)
        for y in 2..<7 {
            for x in 3..<12 {
                XCTAssertEqual(pixel(output, width: 25, x: x, y: y), [0, 0, 0, 255])
            }
        }
        XCTAssertEqual(pixel(output, width: 25, x: 20, y: 15), pixel(pixels(source), width: 47, x: 25, y: 18))
    }

    func testArrowRectangleAndTextAreFlattenedIntoPNG() async throws {
        let source = fixture(width: 160, height: 100)
        for annotation in [
            CaptureAnnotation(kind: .arrow, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 90, y: 60)),
            CaptureAnnotation(kind: .rectangle, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 90, y: 60)),
            CaptureAnnotation(kind: .text, start: CGPoint(x: 10, y: 10), end: .zero, text: "Hello", fontSize: 24)
        ] {
            let result = try await ImageRenderer().render(RenderRequest(image: source,
                edits: CaptureEdits(crop: CGRect(x: 0, y: 0, width: 160, height: 100), annotations: [annotation]), backgroundURL: nil))
            let pngSource = CGImageSourceCreateWithData(result.png as CFData, nil)!
            let decoded = CGImageSourceCreateImageAtIndex(pngSource, 0, nil)!
            XCTAssertNotEqual(pixels(decoded), pixels(source), "Missing \(annotation.kind) annotation")
            XCTAssertEqual(pixels(decoded), pixels(result.image))
        }
    }

    func testMissingBackgroundFailsInsteadOfSilentlyExportingRawCapture() async {
        do {
            _ = try await ImageRenderer().render(RenderRequest(image: fixture(),
                edits: CaptureEdits(crop: CGRect(x: 0, y: 0, width: 47, height: 29),
                                    style: CaptureStyle(backgroundID: "missing")), backgroundURL: nil))
            XCTFail("Expected missing background error")
        } catch ImageRenderer.RenderError.missingBackground { } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testInvalidAndOversizedGeometryFailsBeforeAllocation() async {
        for edits in [
            CaptureEdits(crop: CGRect(x: -1, y: 0, width: 20, height: 20)),
            CaptureEdits(crop: CGRect(x: 0.5, y: 0, width: 20, height: 20)),
            CaptureEdits(crop: .zero),
            CaptureEdits(crop: CGRect(x: 0, y: 0, width: 47, height: 29), style: CaptureStyle(backgroundID: "x", padding: 16_384))
        ] {
            do {
                _ = try await ImageRenderer().render(RenderRequest(image: fixture(), edits: edits, backgroundURL: nil))
                XCTFail("Expected invalid geometry or allocation limit error")
            } catch ImageRenderer.RenderError.invalidGeometry { } catch ImageRenderer.RenderError.imageTooLarge { }
            catch { XCTFail("Unexpected error: \(error)") }
        }
    }
}
