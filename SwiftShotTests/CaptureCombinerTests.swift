import CoreGraphics
import XCTest
@testable import SwiftShot

final class CaptureCombinerTests: XCTestCase {
    func testVerticalCombinesInOrderLeftAlignedWithTransparentPadding() async throws {
        let first = try fixture(width: 2, height: 1, rgba: [255, 0, 0, 255])
        let second = try fixture(width: 1, height: 2, rgba: [0, 0, 255, 255])
        let output = try await CaptureCombiner().combine(images: [first, second], axis: .vertical)
        XCTAssertEqual(output.width, 2)
        XCTAssertEqual(output.height, 3)
        guard output.width == 2, output.height == 3 else { return }
        XCTAssertEqual(try pixel(output, x: 0, y: 0), [255, 0, 0, 255])
        XCTAssertEqual(try pixel(output, x: 1, y: 0), [255, 0, 0, 255])
        XCTAssertEqual(try pixel(output, x: 0, y: 1), [0, 0, 255, 255])
        XCTAssertEqual(try pixel(output, x: 0, y: 2), [0, 0, 255, 255])
        XCTAssertEqual(try pixel(output, x: 1, y: 1), [0, 0, 0, 0])
        XCTAssertEqual(try pixel(output, x: 1, y: 2), [0, 0, 0, 0])
    }

    func testHorizontalCombinesInOrderTopAlignedWithoutResampling() async throws {
        let first = try fixture(width: 1, height: 2, rgba: [0, 255, 0, 255])
        let second = try fixture(width: 2, height: 1, rgba: [255, 0, 0, 255])
        let output = try await CaptureCombiner().combine(images: [first, second], axis: .horizontal)
        XCTAssertEqual(output.width, 3)
        XCTAssertEqual(output.height, 2)
        guard output.width == 3, output.height == 2 else { return }
        XCTAssertEqual(try pixel(output, x: 0, y: 0), [0, 255, 0, 255])
        XCTAssertEqual(try pixel(output, x: 0, y: 1), [0, 255, 0, 255])
        XCTAssertEqual(try pixel(output, x: 1, y: 0), [255, 0, 0, 255])
        XCTAssertEqual(try pixel(output, x: 2, y: 0), [255, 0, 0, 255])
        XCTAssertEqual(try pixel(output, x: 2, y: 1), [0, 0, 0, 0])
    }

    func testPremultipliedAlphaIsPreservedInsteadOfFlattened() async throws {
        let image = try fixture(width: 1, height: 1, rgba: [128, 0, 0, 128])
        let result = try await CaptureCombiner().combine(images: [image, image], axis: .horizontal)
        XCTAssertEqual(result.width, 2)
        guard result.width == 2 else { return }
        XCTAssertEqual(try pixel(result, x: 0, y: 0), [128, 0, 0, 128])
        XCTAssertEqual(try pixel(result, x: 1, y: 0), [128, 0, 0, 128])
    }

    func testSameDisplayP3ProfileIsRetainedAndMixedProfilesNormalizeToSRGB() async throws {
        let p3 = try fixture(width: 1, height: 1, rgba: [255, 0, 0, 255], colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!)
        let srgb = try fixture(width: 1, height: 1, rgba: [0, 255, 0, 255])
        let same = try await CaptureCombiner().combine(images: [p3, p3], axis: .vertical)
        XCTAssertEqual(same.colorSpace?.name, CGColorSpace.displayP3)
        let mixed = try await CaptureCombiner().combine(images: [p3, srgb], axis: .vertical)
        XCTAssertEqual(mixed.colorSpace?.name, CGColorSpace.sRGB)
    }

    func testFloatingPointExtendedRangeValuesAreNotClippedToSDR() async throws {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        let bitmap = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
            .union([.floatComponents, .byteOrder32Little])
        let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 32,
            bytesPerRow: 16, space: space, bitmapInfo: bitmap.rawValue))
        let values = try XCTUnwrap(context.data?.assumingMemoryBound(to: Float.self))
        values[0] = 2
        values[1] = 0.25
        values[2] = 0
        values[3] = 1
        let source = try XCTUnwrap(context.makeImage())
        let output = try await CaptureCombiner().combine(images: [source, source], axis: .horizontal)
        XCTAssertEqual(output.bitsPerComponent, 32)
        XCTAssertTrue(output.bitmapInfo.contains(.floatComponents))
        XCTAssertEqual(output.colorSpace?.name, CGColorSpace.extendedLinearSRGB)
        let data = try XCTUnwrap(output.dataProvider?.data)
        let bytes = try XCTUnwrap(CFDataGetBytePtr(data))
        let first = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
        XCTAssertEqual(Float(bitPattern: first), 2, accuracy: 0.001)
    }

    func testRejectsEmptyInputAndMoreThanThirtyTwoSources() async throws {
        do { _ = try await CaptureCombiner().combine(images: [], axis: .vertical); XCTFail("Empty input must fail") }
        catch { }
        let image = try fixture(width: 1, height: 1, rgba: [0, 0, 0, 255])
        do { _ = try await CaptureCombiner().combine(images: Array(repeating: image, count: 33), axis: .vertical); XCTFail("Source admission must be capped") }
        catch { }
    }

    func testOutputPixelAndPeakWorkingMemoryLimitsAreEnforcedBeforeAllocation() async throws {
        let image = try fixture(width: 2, height: 2, rgba: [0, 0, 0, 255])
        do {
            _ = try await CaptureCombiner(maximumOutputPixels: 7).combine(images: [image, image], axis: .vertical)
            XCTFail("Eight output pixels exceed the configured seven-pixel limit")
        } catch { }
        do {
            _ = try await CaptureCombiner(maximumWorkingBytes: 31).combine(images: [image, image], axis: .vertical)
            XCTFail("The two source buffers alone use 32 bytes, before output and conversion")
        } catch { }
    }

    func testCanceledCombinationNeverProducesAnImage() async throws {
        let image = try fixture(width: 1, height: 1, rgba: [0, 0, 0, 255])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await CaptureCombiner().combine(images: [image], axis: .vertical)
        }
        do { _ = try await task.value; XCTFail("Canceled work must stop before allocation") }
        catch is CancellationError { }
    }

    func testPreflightCountsSourcesOutputCopyAndLargestConversionAtExactBoundary() throws {
        let sources = [CaptureCombineSource(width: 2, height: 2, bytesPerRow: 8),
                       CaptureCombineSource(width: 2, height: 2, bytesPerRow: 8)]
        XCTAssertThrowsError(try CaptureCombiner(maximumWorkingBytes: 127).preflight(sources: sources, axis: .vertical))
        let plan = try CaptureCombiner(maximumWorkingBytes: 128).preflight(sources: sources, axis: .vertical)
        XCTAssertEqual(plan.width, 2)
        XCTAssertEqual(plan.height, 4)
        XCTAssertEqual(plan.admittedSourceBytes, 32)
        XCTAssertEqual(plan.outputBytes, 32)
        XCTAssertEqual(plan.normalizationBytes, 16)
        XCTAssertEqual(plan.estimatedPeakBytes, 128)
    }

    func testPreflightRejectsArithmeticOverflowWithoutAllocatingPixels() throws {
        let overflowing = CaptureCombineSource(width: 1, height: 2, bytesPerRow: Int.max)
        XCTAssertThrowsError(try CaptureCombiner().preflight(sources: [overflowing], axis: .vertical))
        let wide = CaptureCombineSource(width: Int.max, height: 1, bytesPerRow: 4)
        XCTAssertThrowsError(try CaptureCombiner().preflight(sources: [wide, wide], axis: .horizontal))
    }

    func testPreflightCannotRaiseTheHardSixtyFourMegapixelOrMemoryLimits() throws {
        let combiner = CaptureCombiner(maximumOutputPixels: Int.max, maximumWorkingBytes: Int.max)
        let large = CaptureCombineSource(width: 8_001, height: 8_000, bytesPerRow: 32_004)
        XCTAssertThrowsError(try combiner.preflight(sources: [large], axis: .vertical))
        let heavy = CaptureCombineSource(width: 2, height: 2, bytesPerRow: 8, retainedSourceBytes: 512 * 1_024 * 1_024)
        XCTAssertThrowsError(try combiner.preflight(sources: [heavy], axis: .vertical))
    }

    func testRecoveryCombineSourcePredictsEditedSizeAndChargesOriginalWithoutLoadingPixels() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftShotCombineMetadata-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecoveryStore(root: root), id = UUID()
        let image = try fixture(width: 32, height: 24, rgba: [255, 0, 0, 255])
        let edits = CaptureEdits(crop: CGRect(x: 0, y: 0, width: 16, height: 12),
            style: CaptureStyle(backgroundID: "styled", padding: 2, cornerRadius: 0, shadow: 0))
        try await store.persist(id: id, image: image, edits: edits, revision: 0, savedURL: nil)
        let metadata = try await RecoveryStore(root: root).combineSource(id: id)
        XCTAssertEqual(metadata.width, 20)
        XCTAssertEqual(metadata.height, 16)
        XCTAssertGreaterThanOrEqual(metadata.retainedSourceBytes ?? 0, 32 * 24 * 4,
                                    "A small crop may still retain the whole original provider")
        let plan = try CaptureCombiner().preflight(sources: [metadata], axis: .vertical)
        XCTAssertGreaterThanOrEqual(plan.admittedSourceBytes, 32 * 24 * 4)
    }

    private func fixture(width: Int, height: Int, rgba: [UInt8], colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!) throws -> CGImage {
        let data = Data(Array(repeating: rgba, count: width * height).flatMap { $0 })
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try XCTUnwrap(context.data?.assumingMemoryBound(to: UInt8.self))
        return (0..<4).map { bytes[(y * image.width + x) * 4 + $0] }
    }
}
