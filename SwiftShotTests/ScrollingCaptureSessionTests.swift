import CoreGraphics
import XCTest
@testable import SwiftShot

@MainActor
final class ScrollingCaptureSessionTests: XCTestCase {
    func testStartConsumesFramesAndFinishPublishesOneArtifact() async throws {
        let source = FakeScrollingFrameSource()
        let session = ScrollingCaptureSession(source: source)
        let region = try makeRegion()

        try await session.start(for: region)
        source.send(try frame(rows: 0..<6))
        source.send(try frame(rows: 2..<8))
        await eventually { session.state.acceptedFrames == 2 }

        let outcome = try await session.finish()

        guard case let .captured(artifact) = outcome else { return XCTFail("Expected captured artifact") }
        XCTAssertEqual(artifact.acceptedFrames, 2)
        XCTAssertEqual(artifact.image.height, 8)
        XCTAssertEqual(source.startCount, 1)
        XCTAssertEqual(source.stopCount, 1)
        XCTAssertEqual(session.state, .finished)
    }

    func testOneFrameFinishIsAnIntentionalValidCapture() async throws {
        let source = FakeScrollingFrameSource()
        let session = ScrollingCaptureSession(source: source)
        try await session.start(for: makeRegion())
        source.send(try frame(rows: 0..<6))
        await eventually { session.state.acceptedFrames == 1 }

        guard case let .captured(artifact) = try await session.finish() else {
            return XCTFail("Expected captured artifact")
        }
        XCTAssertEqual(artifact.image.height, 6)
    }

    func testCancelStopsSourceAndNeverRendersOrPublishes() async throws {
        let source = FakeScrollingFrameSource()
        let session = ScrollingCaptureSession(source: source)
        try await session.start(for: makeRegion())
        source.send(try frame(rows: 0..<6))

        let outcome = await session.cancel()

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(source.stopCount, 1)
        XCTAssertEqual(session.state, .cancelled)
        await XCTAssertThrowsErrorAsync(try await session.finish())
    }

    func testSourceFailureIsTerminalAndStaleFramesAreIgnored() async throws {
        let source = FakeScrollingFrameSource()
        let session = ScrollingCaptureSession(source: source)
        try await session.start(for: makeRegion())
        source.send(try frame(rows: 0..<6))
        await eventually { session.state.acceptedFrames == 1 }
        source.fail(FakeError.stopped)
        await eventually { if case .failed = session.state { return true }; return false }
        source.send(try frame(rows: 2..<8))

        guard case let .captured(artifact) = try await session.finish() else {
            return XCTFail("Expected the last verified partial capture")
        }
        XCTAssertEqual(artifact.acceptedFrames, 1)
        XCTAssertEqual(artifact.image.height, 6)
    }

    func testDuplicateStartIsRejectedAndStopIsExactlyOnce() async throws {
        let source = FakeScrollingFrameSource()
        let session = ScrollingCaptureSession(source: source)
        try await session.start(for: makeRegion())

        await XCTAssertThrowsErrorAsync(try await session.start(for: makeRegion()))
        _ = await session.cancel()
        _ = await session.cancel()

        XCTAssertEqual(source.startCount, 1)
        XCTAssertEqual(source.stopCount, 1)
    }

    func testHundredSessionLifecycleHasBoundedP95AndBalancedStops() async throws {
        let region = try makeRegion()
        let first = try frame(rows: 0..<6)
        let second = try frame(rows: 2..<8)
        let clock = ContinuousClock()
        var durations = [Duration]()
        durations.reserveCapacity(100)

        for _ in 0..<100 {
            let source = FakeScrollingFrameSource()
            let session = ScrollingCaptureSession(source: source)
            let started = clock.now
            try await session.start(for: region)
            source.send(first)
            source.send(second)
            await eventually { session.state.acceptedFrames == 2 }
            _ = try await session.finish()
            durations.append(started.duration(to: clock.now))
            XCTAssertEqual(source.startCount, 1)
            XCTAssertEqual(source.stopCount, 1)
        }

        let p95 = durations.sorted()[94]
        XCTAssertLessThan(p95, .milliseconds(100), "Small-frame session p95 regressed: \(p95)")
    }

    private func eventually(_ predicate: @escaping @MainActor () -> Bool) async {
        for _ in 0..<100 {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("Condition did not become true")
    }

    private func makeRegion() throws -> CaptureRegionReference {
        let image = try frame(rows: 0..<6).image
        let screen = FrozenScreen(id: 42, frame: CGRect(x: 0, y: 0, width: 6, height: 6), image: image, windows: [])
        return try XCTUnwrap(CaptureRegionReference(screen: screen,
            crop: CGRect(x: 0, y: 0, width: 6, height: 6), isPrivate: false))
    }

    private func frame(rows: Range<Int>) throws -> ScrollingCaptureFrame {
        let width = 6
        var bytes = [UInt8]()
        bytes.reserveCapacity(rows.count * width * 4)
        for row in rows {
            for x in 0..<width {
                bytes.append(UInt8((row * 37 + x * 17) % 251))
                bytes.append(UInt8((row * 67 + x * 29 + 11) % 253))
                bytes.append(UInt8((row * 97 + x * 43 + 23) % 255))
                bytes.append(255)
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: rows.count, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
                .union(.byteOrder32Big), provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent))
        return ScrollingCaptureFrame(image: image, pointPixelScale: 1)
    }
}

private enum FakeError: Error { case stopped }

@MainActor
private final class FakeScrollingFrameSource: ScrollingFrameSource {
    private var continuation: AsyncThrowingStream<ScrollingCaptureFrame, Error>.Continuation?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start(for region: CaptureRegionReference) async throws -> AsyncThrowingStream<ScrollingCaptureFrame, Error> {
        startCount += 1
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(3)) { continuation in
            self.continuation = continuation
        }
    }

    func stop() async {
        guard continuation != nil else { return }
        stopCount += 1
        continuation?.finish()
        continuation = nil
    }

    func send(_ frame: ScrollingCaptureFrame) { continuation?.yield(frame) }
    func fail(_ error: Error) { continuation?.finish(throwing: error); continuation = nil }
}

private extension ScrollingCaptureSessionState {
    var acceptedFrames: Int {
        if case let .capturing(progress, _) = self { return progress.acceptedFrames }
        return 0
    }
}

@MainActor
private func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T,
                                          file: StaticString = #filePath, line: UInt = #line) async {
    do { _ = try await expression(); XCTFail("Expected an error", file: file, line: line) }
    catch { }
}
