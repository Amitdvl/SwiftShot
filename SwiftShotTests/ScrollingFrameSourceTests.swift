import CoreMedia
import ScreenCaptureKit
import XCTest
@testable import SwiftShot

@MainActor
final class ScrollingFrameSourceTests: XCTestCase {
    func testInputPacingPreservesFastGestureExtentOneProcessedFrameAtATime() throws {
        var buffer = ScrollingInputPacer.Buffer()
        buffer.enqueue(-355)

        var steps = [Int32]()
        while buffer.pendingPoints != 0 {
            XCTAssertNil(buffer.nextStep(maximumMagnitude: 32),
                         "Wall-clock ticks must not outrun processed capture frames")
            buffer.frameWasProcessed(.appended(rows: 32))
            steps.append(try XCTUnwrap(buffer.nextStep(maximumMagnitude: 32)))
        }

        XCTAssertEqual(steps.reduce(0, +), -355)
        XCTAssertEqual(steps.dropLast(), Array(repeating: -32, count: 11))
        XCTAssertEqual(steps.last, -3)
        XCTAssertEqual(buffer.pendingPoints, 0)
    }

    func testInputPacingCombinesDirectionChangesWithoutOvershoot() {
        var buffer = ScrollingInputPacer.Buffer()
        buffer.enqueue(-80)
        buffer.enqueue(30)

        buffer.frameWasProcessed(.firstFrame)
        XCTAssertEqual(buffer.nextStep(maximumMagnitude: 32), -32)
        XCTAssertNil(buffer.nextStep(maximumMagnitude: 32))
        buffer.frameWasProcessed(.unchanged)
        XCTAssertEqual(buffer.nextStep(maximumMagnitude: 32), -18)
        XCTAssertNil(buffer.nextStep(maximumMagnitude: 32))
    }

    func testEveryProcessedFrameReleasesBufferedInputWithoutDeadlocking() throws {
        var buffer = ScrollingInputPacer.Buffer()
        buffer.enqueue(-96)

        for disposition: ScrollingIngestDisposition in [
            .firstFrame,
            .unchanged,
            .rejected(.insufficientTexture)
        ] {
            buffer.frameWasProcessed(disposition)
            XCTAssertEqual(try XCTUnwrap(buffer.nextStep(maximumMagnitude: 32)), -32)
        }

        XCTAssertEqual(buffer.pendingPoints, 0)
    }

    func testMissingFrameDispositionDoesNotReleaseBufferedInput() {
        var buffer = ScrollingInputPacer.Buffer()
        buffer.enqueue(-32)

        buffer.frameWasProcessed(nil)

        XCTAssertNil(buffer.nextStep(maximumMagnitude: 32))
        XCTAssertEqual(buffer.pendingPoints, -32)
    }

    func testInputPacingStepScalesWithEveryViewportHeight() {
        for height in [24.0, 48, 96, 240, 480, 960, 1_290] {
            let step = ScrollingInputPacer.maximumStepPoints(viewportHeight: height)

            XCTAssertGreaterThanOrEqual(step, 1)
            XCTAssertLessThanOrEqual(step, 32)
            XCTAssertLessThanOrEqual(step, max(1, height / 8),
                                     "A step must preserve overlap for a \(height)-point viewport")
        }
    }

    func testConfigurationUsesNativeRegionPixelsAndBoundedCadence() throws {
        let region = try makeRegion()

        let configuration = try ScreenCaptureKitScrollingFrameSource.configuration(
            for: region, pointPixelScale: 2, queueDepth: 3)

        XCTAssertEqual(configuration.width, 100)
        XCTAssertEqual(configuration.height, 60)
        XCTAssertEqual(configuration.sourceRect, CGRect(x: 10, y: 5, width: 50, height: 30))
        XCTAssertEqual(configuration.queueDepth, 3)
        XCTAssertEqual(configuration.pixelFormat, kCVPixelFormatType_32BGRA)
        XCTAssertEqual(configuration.captureResolution, .best)
        XCTAssertFalse(configuration.showsCursor)
        XCTAssertFalse(configuration.scalesToFit)
        XCTAssertTrue(configuration.shouldBeOpaque)
        XCTAssertTrue(CFEqual(configuration.colorSpaceName, CGColorSpace.sRGB as CFString))
        XCTAssertEqual(CMTimeCompare(configuration.minimumFrameInterval, CMTime(value: 1, timescale: 60)), 0)
    }

    func testDefaultConfigurationAndFrameBufferFavorContinuity() throws {
        let region = try makeRegion()
        let configuration = try ScreenCaptureKitScrollingFrameSource.configuration(
            for: region, pointPixelScale: 2)

        XCTAssertEqual(configuration.queueDepth,
                       ScreenCaptureKitScrollingFrameSource.streamQueueDepth)
        XCTAssertEqual(CMTimeCompare(configuration.minimumFrameInterval,
                                     CMTime(value: 1, timescale: 60)), 0)
        XCTAssertEqual(ScreenCaptureKitScrollingFrameSource.bufferedFrameCapacity, 8)
    }

    func testConfigurationRejectsUnboundedWindowServerQueue() throws {
        let region = try makeRegion()

        for queueDepth in [0, 9] {
            XCTAssertThrowsError(try ScreenCaptureKitScrollingFrameSource.configuration(
                for: region, pointPixelScale: 2, queueDepth: queueDepth)) { error in
                XCTAssertEqual(error as? ScrollingFrameSourceError, .invalidQueueDepth(queueDepth))
            }
        }
    }

    func testConfigurationFailsClosedWhenLiveDisplayScaleDiffersFromSelection() throws {
        let region = try makeRegion()

        XCTAssertThrowsError(try ScreenCaptureKitScrollingFrameSource.configuration(
            for: region, pointPixelScale: 1, queueDepth: 3)) { error in
            XCTAssertEqual(error as? ScrollingFrameSourceError, .scaleMismatch(expected: 2, actual: 1))
        }
    }

    private func makeRegion() throws -> CaptureRegionReference {
        let context = try XCTUnwrap(CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8,
            bytesPerRow: 800, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let screen = FrozenScreen(id: 42, frame: CGRect(x: 0, y: 0, width: 100, height: 50), image: image, windows: [])
        return try XCTUnwrap(CaptureRegionReference(screen: screen,
            crop: CGRect(x: 20, y: 10, width: 100, height: 60), isPrivate: false))
    }
}
