import XCTest
@testable import SwiftShot

final class CaptureRegionReferenceTests: XCTestCase {
    func testRetinaRegionUsesLocalPointsAndRejectsChangedScaleOrDisplayFrame() throws {
        let large = try image(width: 200, height: 120)
        let screen = FrozenScreen(id: 7, frame: CGRect(x: -100, y: 50, width: 100, height: 60), image: large, windows: [])
        let region = try XCTUnwrap(CaptureRegionReference(screen: screen, crop: CGRect(x: 20, y: 10, width: 80, height: 40), isPrivate: true))
        XCTAssertEqual(region.rect, CGRect(x: 10, y: 5, width: 40, height: 20))
        XCTAssertTrue(region.isPrivate)
        XCTAssertTrue(region.matches(frame: screen.frame, image: try image(width: 80, height: 40)))
        XCTAssertFalse(region.matches(frame: screen.frame, image: try image(width: 40, height: 20)))
        XCTAssertFalse(region.matches(frame: screen.frame.offsetBy(dx: 1, dy: 0), image: try image(width: 80, height: 40)))
    }

    func testLiveWindowPlaceholderIsNotARecapturableRegion() throws {
        let screen = FrozenScreen(id: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            image: try image(width: 1, height: 1), windows: [], isLive: true)
        XCTAssertNil(CaptureRegionReference(screen: screen, crop: CGRect(x: 0, y: 0, width: 10, height: 10), isPrivate: false))
    }

    // Recapture pixels start at the selected region, not the display origin.
    func testRecapturedLocalCropRetainsDisplayOffsetScaleAndPrivacy() throws {
        let region = try reference()
        let cropped = try XCTUnwrap(region.applyingCrop(CGRect(x: 12, y: 8, width: 40, height: 20),
            relativeToCapturedRegion: true))
        XCTAssertEqual(cropped.displayID, 7)
        XCTAssertEqual(cropped.displayFrame, CGRect(x: -100, y: 50, width: 100, height: 60))
        XCTAssertEqual(cropped.rect, CGRect(x: 16, y: 9, width: 20, height: 10))
        XCTAssertEqual(cropped.nativeSize, CGSize(width: 40, height: 20))
        XCTAssertTrue(cropped.isPrivate)
    }

    // A second recapture is based on its own immutable region, once per image.
    func testCroppingARecaptureOfAnAlreadyCroppedRegionDoesNotLoseOffset() throws {
        let region = try reference()
        let first = try XCTUnwrap(region.applyingCrop(CGRect(x: 12, y: 8, width: 40, height: 20),
            relativeToCapturedRegion: true))
        let second = try XCTUnwrap(first.applyingCrop(CGRect(x: 4, y: 2, width: 20, height: 10),
            relativeToCapturedRegion: true))
        XCTAssertEqual(second.rect, CGRect(x: 18, y: 10, width: 10, height: 5))
        XCTAssertEqual(second.nativeSize, CGSize(width: 20, height: 10))
        XCTAssertTrue(second.isPrivate)
    }

    // Crop changes on the same original must not accumulate the previous change.
    func testMultipleCropEditsUseTheSameImmutableCapturedRegionOrigin() throws {
        let region = try reference()
        _ = try XCTUnwrap(region.applyingCrop(CGRect(x: 12, y: 8, width: 40, height: 20),
            relativeToCapturedRegion: true))
        let revised = try XCTUnwrap(region.applyingCrop(CGRect(x: 4, y: 2, width: 20, height: 10),
            relativeToCapturedRegion: true))
        XCTAssertEqual(revised.rect, CGRect(x: 12, y: 6, width: 10, height: 5))
    }

    // A full-display frozen image keeps the existing absolute pixel convention.
    func testOriginalFullDisplayCropDoesNotAddThePreviousRegionOffset() throws {
        let region = try reference()
        let cropped = try XCTUnwrap(region.applyingCrop(CGRect(x: 40, y: 20, width: 60, height: 30)))
        XCTAssertEqual(cropped.rect, CGRect(x: 20, y: 10, width: 30, height: 15))
        XCTAssertEqual(cropped.nativeSize, CGSize(width: 60, height: 30))
        XCTAssertTrue(cropped.isPrivate)
    }

    // A crop inside the display can still be outside the much smaller recapture.
    func testLocalCropOutsideRecapturedNativePixelsIsRejected() throws {
        let region = try reference()
        for crop in [CGRect(x: 70, y: 0, width: 20, height: 20),
                     CGRect(x: 0, y: 35, width: 20, height: 10),
                     CGRect(x: -1, y: 0, width: 20, height: 20),
                     CGRect(x: 0, y: -1, width: 20, height: 20)] {
            XCTAssertNil(region.applyingCrop(crop, relativeToCapturedRegion: true))
        }
    }

    func testUncroppedRecaptureKeepsExactlyTheOriginalRegion() throws {
        let region = try reference()
        let unchanged = try XCTUnwrap(region.applyingCrop(CGRect(x: 0, y: 0, width: 80, height: 40),
            relativeToCapturedRegion: true))
        XCTAssertEqual(unchanged.rect, CGRect(x: 10, y: 5, width: 40, height: 20))
        XCTAssertEqual(unchanged.nativeSize, CGSize(width: 80, height: 40))
    }

    func testOriginalCropOutsideFullDisplayPixelsIsRejected() throws {
        let region = try reference()
        for crop in [CGRect(x: 195, y: 0, width: 10, height: 10),
                     CGRect(x: 0, y: 115, width: 10, height: 10),
                     CGRect(x: -1, y: 0, width: 10, height: 10),
                     CGRect(x: 0, y: -1, width: 10, height: 10),
                     CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10)] {
            XCTAssertNil(region.applyingCrop(crop))
        }
    }

    // Existing saved geometry has no image-origin field; the call specifies mode.
    func testExistingCodableRegionCanDriveBothCoordinateModes() throws {
        let original = try reference()
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CaptureRegionReference.self, from: encoded)
        let full = try XCTUnwrap(decoded.applyingCrop(CGRect(x: 12, y: 8, width: 40, height: 20)))
        let local = try XCTUnwrap(decoded.applyingCrop(CGRect(x: 12, y: 8, width: 40, height: 20),
            relativeToCapturedRegion: true))
        XCTAssertEqual(full.rect, CGRect(x: 6, y: 4, width: 20, height: 10))
        XCTAssertEqual(local.rect, CGRect(x: 16, y: 9, width: 20, height: 10))
        XCTAssertTrue(local.isPrivate)
    }

    private func reference() throws -> CaptureRegionReference {
        let screen = FrozenScreen(id: 7, frame: CGRect(x: -100, y: 50, width: 100, height: 60),
            image: try image(width: 200, height: 120), windows: [])
        return try XCTUnwrap(CaptureRegionReference(screen: screen,
            crop: CGRect(x: 20, y: 10, width: 80, height: 40), isPrivate: true))
    }

    private func image(width: Int, height: Int) throws -> CGImage {
        try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
    }
}
