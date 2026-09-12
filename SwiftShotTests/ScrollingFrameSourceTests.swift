import CoreMedia
import ScreenCaptureKit
import XCTest
@testable import SwiftShot

@MainActor
final class ScrollingFrameSourceTests: XCTestCase {
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
        XCTAssertEqual(CMTimeCompare(configuration.minimumFrameInterval, CMTime(value: 1, timescale: 15)), 0)
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
