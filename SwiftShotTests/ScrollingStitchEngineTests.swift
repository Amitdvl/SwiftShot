import CoreGraphics
import XCTest

#if canImport(SwiftShot)
@testable import SwiftShot
#endif

final class ScrollingStitchEngineTests: XCTestCase {
    func testFirstFrameSeedsProgressAndRendersExactPixels() async throws {
        let source = try image(rows: documentRows(0..<6, width: 5), width: 5)
        let engine = ScrollingStitchEngine()

        let result = try await engine.ingest(frame(source, scale: 2))

        XCTAssertEqual(result.disposition, .firstFrame)
        XCTAssertEqual(result.progress, ScrollingStitchProgress(
            acceptedFrames: 1, outputWidth: 5, outputHeight: 6, retainedBytes: 270))
        let artifact = try await engine.render()
        XCTAssertEqual(artifact.acceptedFrames, 1)
        XCTAssertEqual(artifact.appendedRows, 0)
        XCTAssertEqual(try pixels(artifact.image), try pixels(source))
    }

    func testArbitraryDownwardOffsetsAppendOnlyNewRowsWithExactFinalPixels() async throws {
        let rows = documentRows(0..<11, width: 7)
        let engine = ScrollingStitchEngine()
        _ = try await engine.ingest(frame(try image(rows: Array(rows[0..<6]), width: 7)))

        let second = try await engine.ingest(frame(try image(rows: Array(rows[2..<8]), width: 7)))
        let third = try await engine.ingest(frame(try image(rows: Array(rows[5..<11]), width: 7)))

        XCTAssertEqual(second.disposition, .appended(rows: 2))
        XCTAssertEqual(third.disposition, .appended(rows: 3))
        let artifact = try await engine.render()
        XCTAssertEqual(artifact.appendedRows, 5)
        XCTAssertEqual(try pixels(artifact.image), try pixels(image(rows: rows, width: 7)))
    }

    func testUnchangedTexturedFrameDoesNotMutateComposite() async throws {
        let source = try image(rows: documentRows(0..<6, width: 6), width: 6)
        let engine = ScrollingStitchEngine()
        _ = try await engine.ingest(frame(source))

        let result = try await engine.ingest(frame(source))

        XCTAssertEqual(result.disposition, .unchanged)
        XCTAssertEqual(result.progress.acceptedFrames, 1)
        let artifact = try await engine.render()
        XCTAssertEqual(try pixels(artifact.image), try pixels(source))
    }

    func testSmallRGBNoiseStillFindsTheDownwardSeam() async throws {
        let rows = documentRows(0..<8, width: 8)
        let engine = ScrollingStitchEngine()
        _ = try await engine.ingest(frame(try image(rows: Array(rows[0..<6]), width: 8)))
        let noisy = addNoise(to: Array(rows[2..<8]), amount: 2)

        let result = try await engine.ingest(frame(try image(rows: noisy, width: 8)))

        XCTAssertEqual(result.disposition, .appended(rows: 2))
        XCTAssertEqual(result.progress.outputHeight, 8)
    }

    func testPeriodicDynamicRowsDoNotHideAnOtherwiseConfidentSeam() async throws {
        let width = 128
        let viewportHeight = 480
        let shift = 40
        let rows = documentRows(0..<(viewportHeight + shift), width: width)
        let engine = ScrollingStitchEngine()
        _ = try await engine.ingest(frame(try image(
            rows: Array(rows[0..<viewportHeight]), width: width)))
        var nextRows = Array(rows[shift..<(viewportHeight + shift)])
        for row in stride(from: 0, to: viewportHeight - shift, by: 9) {
            for byte in nextRows[row].indices where byte % 4 != 3 {
                nextRows[row][byte] = UInt8(clamping: Int(nextRows[row][byte]) + 40)
            }
        }

        let result = try await engine.ingest(frame(try image(rows: nextRows, width: width)))

        XCTAssertEqual(result.disposition, .appended(rows: shift))
    }

    func testSparseRepeatedPageUsesNarrowUniqueMarkersToDisambiguateTheSeam() async throws {
        let width = 1_440
        let viewportHeight = 960
        let shift = 80
        let rows = sparseRepeatedPageRows(count: viewportHeight + shift, width: width)
        let engine = ScrollingStitchEngine()
        _ = try await engine.ingest(frame(try image(
            rows: Array(rows[0..<viewportHeight]), width: width)))

        let next = try image(rows: Array(rows[shift..<(viewportHeight + shift)]), width: width)
        let result = try await engine.ingest(frame(next))

        XCTAssertEqual(result.disposition, .appended(rows: shift))
        XCTAssertEqual(result.progress.outputHeight, viewportHeight + shift)
    }

    func testStickyTopAndBottomRowsAppearExactlyOnce() async throws {
        let width = 7
        let content = documentRows(0..<10, width: width)
        let header = specialRow(seed: 241, width: width)
        let footer = specialRow(seed: 199, width: width)
        func viewport(_ start: Int) throws -> CGImage {
            try image(rows: [header] + Array(content[start..<(start + 6)]) + [footer], width: width)
        }
        let engine = ScrollingStitchEngine()
        _ = try await engine.ingest(frame(try viewport(0)))

        let second = try await engine.ingest(frame(try viewport(2)))
        let third = try await engine.ingest(frame(try viewport(4)))
        XCTAssertEqual(second.disposition, .appended(rows: 2))
        XCTAssertEqual(third.disposition, .appended(rows: 2))

        let expected = try image(rows: [header] + content + [footer], width: width)
        let artifact = try await engine.render()
        XCTAssertEqual(artifact.image.height, 12)
        XCTAssertEqual(try pixels(artifact.image), try pixels(expected))
    }

    func testRepeatedPatternIsRejectedWithoutMutatingAcceptedResult() async throws {
        let width = 6
        let a = specialRow(seed: 31, width: width)
        let b = specialRow(seed: 173, width: width)
        let repeated = try image(rows: [a, b, a, b, a, b], width: width)
        let shifted = try image(rows: [b, a, b, a, b, a], width: width)
        let engine = ScrollingStitchEngine()
        _ = try await engine.ingest(frame(repeated))

        let result = try await engine.ingest(frame(shifted))

        XCTAssertEqual(result.disposition, .rejected(.ambiguousOverlap))
        XCTAssertEqual(result.progress.acceptedFrames, 1)
        let artifact = try await engine.render()
        XCTAssertEqual(try pixels(artifact.image), try pixels(repeated))
    }

    func testBlankFrameIsRejectedWithoutMutatingAcceptedResult() async throws {
        let blank = try image(rows: Array(repeating: solidRow(20, width: 6), count: 6), width: 6)
        let engine = ScrollingStitchEngine()
        _ = try await engine.ingest(frame(blank))

        let result = try await engine.ingest(frame(blank))

        XCTAssertEqual(result.disposition, .rejected(.insufficientTexture))
        let artifact = try await engine.render()
        XCTAssertEqual(try pixels(artifact.image), try pixels(blank))
    }

    func testReverseMotionIsRejectedWithoutMutatingAcceptedResult() async throws {
        let rows = documentRows(0..<10, width: 7)
        let initial = try image(rows: Array(rows[4..<10]), width: 7)
        let engine = ScrollingStitchEngine()
        _ = try await engine.ingest(frame(initial))

        let result = try await engine.ingest(frame(try image(rows: Array(rows[2..<8]), width: 7)))

        XCTAssertEqual(result.disposition, .rejected(.reverseMotion))
        let artifact = try await engine.render()
        XCTAssertEqual(try pixels(artifact.image), try pixels(initial))
    }

    func testDimensionAndScaleMismatchesFailWithoutMutatingAcceptedResult() async throws {
        let source = try image(rows: documentRows(0..<6, width: 6), width: 6)
        let engine = ScrollingStitchEngine()
        _ = try await engine.ingest(frame(source, scale: 2))

        await assertError(.dimensionMismatch(expectedWidth: 6, expectedHeight: 6, actualWidth: 5, actualHeight: 6)) {
            _ = try await engine.ingest(self.frame(try self.image(rows: self.documentRows(0..<6, width: 5), width: 5), scale: 2))
        }
        await assertError(.scaleMismatch(expected: 2, actual: 1)) {
            _ = try await engine.ingest(self.frame(source, scale: 1))
        }
        let artifact = try await engine.render()
        XCTAssertEqual(try pixels(artifact.image), try pixels(source))
    }

    func testFramePixelCapIsPreflightedBeforeFirstMutation() async throws {
        let limits = ScrollingStitchLimits(maximumFramePixels: 35)
        let engine = ScrollingStitchEngine(limits: limits)
        let source = try image(rows: documentRows(0..<6, width: 6), width: 6)

        await assertError(.framePixelLimitExceeded(limit: 35, actual: 36)) {
            _ = try await engine.ingest(self.frame(source))
        }
        await assertError(.noFrames) { _ = try await engine.render() }
    }

    func testAcceptedFrameCapIsPreflightedBeforeAppend() async throws {
        let rows = documentRows(0..<8, width: 6)
        let engine = ScrollingStitchEngine(limits: ScrollingStitchLimits(maximumAcceptedFrames: 1))
        let initial = try image(rows: Array(rows[0..<6]), width: 6)
        _ = try await engine.ingest(frame(initial))

        await assertError(.acceptedFrameLimitExceeded(limit: 1)) {
            _ = try await engine.ingest(self.frame(try self.image(rows: Array(rows[2..<8]), width: 6)))
        }
        let artifact = try await engine.render()
        XCTAssertEqual(try pixels(artifact.image), try pixels(initial))
    }

    func testOutputPixelCapIsPreflightedBeforeAppend() async throws {
        let rows = documentRows(0..<8, width: 6)
        let engine = ScrollingStitchEngine(limits: ScrollingStitchLimits(maximumOutputPixels: 47))
        let initial = try image(rows: Array(rows[0..<6]), width: 6)
        _ = try await engine.ingest(frame(initial))

        await assertError(.outputPixelLimitExceeded(limit: 47, actual: 48)) {
            _ = try await engine.ingest(self.frame(try self.image(rows: Array(rows[2..<8]), width: 6)))
        }
        let artifact = try await engine.render()
        XCTAssertEqual(try pixels(artifact.image), try pixels(initial))
    }

    func testMemoryCapIsPreflightedBeforeFirstMutation() async throws {
        let engine = ScrollingStitchEngine(limits: ScrollingStitchLimits(maximumRetainedBytes: 287))
        let source = try image(rows: documentRows(0..<6, width: 6), width: 6)

        await assertError(.memoryLimitExceeded(limit: 287, required: 324)) {
            _ = try await engine.ingest(self.frame(source))
        }
        await assertError(.noFrames) { _ = try await engine.render() }
    }

    func testCancellationIsTerminalAndTyped() async throws {
        let engine = ScrollingStitchEngine()
        await engine.cancel()
        let source = try image(rows: documentRows(0..<6, width: 6), width: 6)

        await assertError(.cancelled) { _ = try await engine.ingest(self.frame(source)) }
        await assertError(.cancelled) { _ = try await engine.render() }
    }

    private func frame(_ image: CGImage, scale: CGFloat = 1) -> ScrollingCaptureFrame {
        ScrollingCaptureFrame(image: image, pointPixelScale: scale)
    }

    private func documentRows(_ range: Range<Int>, width: Int) -> [[UInt8]] {
        range.map { row in
            (0..<width).flatMap { x -> [UInt8] in
                [UInt8((row * 37 + x * 17) % 251), UInt8((row * 67 + x * 29 + 11) % 253),
                 UInt8((row * 97 + x * 43 + 23) % 255), 255]
            }
        }
    }

    private func specialRow(seed: Int, width: Int) -> [UInt8] {
        var row = [UInt8]()
        row.reserveCapacity(width * 4)
        for x in 0..<width {
            row.append(UInt8((seed + x * 19) % 256))
            row.append(UInt8((seed * 3 + x * 41) % 256))
            row.append(UInt8((seed * 7 + x * 13) % 256))
            row.append(255)
        }
        return row
    }

    private func solidRow(_ value: UInt8, width: Int) -> [UInt8] {
        Array(repeating: [value, value, value, UInt8(255)], count: width).flatMap { $0 }
    }

    private func addNoise(to rows: [[UInt8]], amount: UInt8) -> [[UInt8]] {
        rows.enumerated().map { rowIndex, row in
            row.enumerated().map { byteIndex, value in
                guard byteIndex % 4 != 3 else { return value }
                let delta = rowIndex.isMultiple(of: 2) ? Int(amount) : -Int(amount)
                return UInt8(clamping: Int(value) + delta)
            }
        }
    }

    /// Browser-like pages contain lots of white space and repeat the same card
    /// geometry. The identity signal can be much narrower than a fixed sampling
    /// stride, so every source pixel must contribute to the seam fingerprint.
    private func sparseRepeatedPageRows(count: Int, width: Int) -> [[UInt8]] {
        (0..<count).map { row in
            let section = row / 384
            let local = row % 384
            return (0..<width).flatMap { x -> [UInt8] in
                let value: UInt8
                if (20..<44).contains(local), (80..<620).contains(x) {
                    value = 28
                } else if (120..<132).contains(local), (60..<1_220).contains(x) {
                    value = 112
                } else if (50..<62).contains(local), (11..<20).contains(x) {
                    value = UInt8(32 + (section * 47) % 180)
                } else {
                    value = 248
                }
                return [value, value, value, 255]
            }
        }
    }

    private func image(rows: [[UInt8]], width: Int) throws -> CGImage {
        XCTAssertFalse(rows.isEmpty)
        XCTAssertTrue(rows.allSatisfy { $0.count == width * 4 })
        let data = Data(rows.flatMap { $0 }) as CFData
        let provider = try XCTUnwrap(CGDataProvider(data: data))
        return try XCTUnwrap(CGImage(width: width, height: rows.count, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
                .union(.byteOrder32Big), provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent))
    }

    private func pixels(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
                .union(.byteOrder32Big).rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes
    }

    private func assertError(_ expected: ScrollingStitchError,
                             operation: () async throws -> Void,
                             file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch let error as ScrollingStitchError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }
}
