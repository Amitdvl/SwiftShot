import XCTest
import AppKit
@testable import SwiftShot

final class OverlayGeometryTests: XCTestCase {
    func testRetinaCropPreservesOriginalPixelsAndRoundsOutward() {
        let result = OverlayGeometry.pixels(from: CGRect(x: 10.25, y: 20.5, width: 100.5, height: 80),
            imageFrame: CGRect(x: 0, y: 0, width: 1440, height: 900), pixelSize: CGSize(width: 2880, height: 1800))
        XCTAssertEqual(result, CGRect(x: 20, y: 41, width: 202, height: 160))
    }

    func testMixedScaleDisplaySelectionClampsToStartingDisplay() {
        let local = OverlayGeometry.rectangle(from: CGPoint(x: 1500, y: 850), to: CGPoint(x: 2500, y: 1200),
                                               bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let result = OverlayGeometry.pixels(from: local, imageFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                           pixelSize: CGSize(width: 2880, height: 1620))
        XCTAssertEqual(result, CGRect(x: 2250, y: 1275, width: 630, height: 345))
    }

    func testNegativeGlobalOriginDoesNotEnterLocalPixelTransform() {
        let globalDisplay = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
        let local = CGRect(x: 120, y: 200, width: 500, height: 400)
        let frame = OverlayGeometry.imageFrame(imageSize: CGSize(width: 3840, height: 2160), screenSize: globalDisplay.size)
        XCTAssertEqual(OverlayGeometry.pixels(from: local, imageFrame: frame, pixelSize: CGSize(width: 3840, height: 2160)),
                       CGRect(x: 240, y: 400, width: 1000, height: 800))
    }

    func testReopenAspectFitDoesNotStretchDifferentDisplayShape() {
        let frame = OverlayGeometry.imageFrame(imageSize: CGSize(width: 2000, height: 1000), screenSize: CGSize(width: 1000, height: 1000))
        XCTAssertEqual(frame, CGRect(x: 0, y: 250, width: 1000, height: 500))
        XCTAssertEqual(OverlayGeometry.pixels(from: frame, imageFrame: frame, pixelSize: CGSize(width: 2000, height: 1000)),
                       CGRect(x: 0, y: 0, width: 2000, height: 1000))
    }

    func testWindowSnapshotCropMapsToOriginalWindowPlacement() {
        let placement = CGRect(x: 240, y: 170, width: 800, height: 500)
        let snapshotPixels = CGSize(width: 1600, height: 1000)
        let fullImage = CGRect(origin: .zero, size: snapshotPixels)
        XCTAssertEqual(OverlayGeometry.points(from: fullImage, imageFrame: placement, pixelSize: snapshotPixels), placement)
        let crop = CGRect(x: 100, y: 80, width: 400, height: 300)
        let onScreen = OverlayGeometry.points(from: crop, imageFrame: placement, pixelSize: snapshotPixels)
        XCTAssertEqual(onScreen, CGRect(x: 290, y: 210, width: 200, height: 150))
        XCTAssertEqual(OverlayGeometry.pixels(from: onScreen, imageFrame: placement, pixelSize: snapshotPixels), crop)
        let edgeDrag = OverlayGeometry.rectangle(from: CGPoint(x: 300, y: 250), to: CGPoint(x: 1400, y: 900), bounds: placement)
        XCTAssertEqual(OverlayGeometry.pixels(from: edgeDrag, imageFrame: placement, pixelSize: snapshotPixels),
                       CGRect(x: 120, y: 160, width: 1480, height: 840))
    }

    func testToolbarClampsAtAllEdgesIncludingExpandedInspector() {
        let screen = CGSize(width: 800, height: 600)
        for x: CGFloat in [0, 700] {
            for y: CGFloat in [0, 550] {
                let frame = OverlayGeometry.toolbarFrame(selection: CGRect(x: x, y: y, width: 100, height: 50),
                    size: CGSize(width: 428, height: 530), screen: screen)
                XCTAssertGreaterThanOrEqual(frame.minX, 14)
                XCTAssertGreaterThanOrEqual(frame.minY, 14)
                XCTAssertLessThanOrEqual(frame.maxX, 786)
                XCTAssertLessThanOrEqual(frame.maxY, 586)
            }
        }
    }

    func testExpandedToolbarFitsOnFirstLayoutWithoutMeasurementFeedback() {
        let screen = CGSize(width: 1280, height: 800)
        let layout = OverlayToolbarLayout(screen: screen, topInset: 14, inspectorHeight: 440, hasTextEntry: false, hasStatus: false)
        let frame = layout.frame(near: CGRect(x: 150, y: 90, width: 950, height: 620))
        XCTAssertEqual(layout.inspectorHeight, 440)
        XCTAssertEqual(frame.height, 539)
        XCTAssertGreaterThanOrEqual(frame.minY, 14)
        XCTAssertLessThanOrEqual(frame.maxY, 786)
    }

    func testSmallDisplayScrollsInspectorAndRespectsNotchAndManualPosition() {
        let screen = CGSize(width: 800, height: 480)
        let layout = OverlayToolbarLayout(screen: screen, topInset: 40, inspectorHeight: 440, hasTextEntry: true, hasStatus: true)
        XCTAssertEqual(layout.inspectorHeight, 215)
        for origin in [CGPoint(x: -500, y: -500), CGPoint(x: 2000, y: 2000)] {
            let frame = layout.frame(near: CGRect(origin: .zero, size: screen), manualOrigin: origin)
            XCTAssertGreaterThanOrEqual(frame.minX, 14)
            XCTAssertGreaterThanOrEqual(frame.minY, 40)
            XCTAssertLessThanOrEqual(frame.maxX, 786)
            XCTAssertLessThanOrEqual(frame.maxY, 466)
        }
    }

    func testMoveAndResizeCannotEscapeDisplayOrInvertBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let rect = CGRect(x: 100, y: 100, width: 200, height: 150)
        XCTAssertEqual(OverlayGeometry.moved(rect, by: CGSize(width: -500, height: 1000), in: bounds),
                       CGRect(x: 0, y: 650, width: 200, height: 150))
        let resized = OverlayGeometry.resized(rect, handle: 0, to: CGPoint(x: 500, y: 500), in: bounds)
        XCTAssertEqual(resized, CGRect(x: 298, y: 248, width: 2, height: 2))
    }
}
