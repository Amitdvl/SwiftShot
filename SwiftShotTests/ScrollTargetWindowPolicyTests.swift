import CoreGraphics
import Darwin
import XCTest
@testable import SwiftShot

/// Exercises the production-used pure admission boundary. These literal rows
/// model external native observations, not app-name/layer exemptions or mocks
/// of the policy. Actual AX/NSWindow lookup and final-hit revalidation require
/// the lead's separate integration/native checks.
final class ScrollTargetWindowPolicyTests: XCTestCase {
    private typealias Window = ScrollTargetWindowPolicy.Window
    private let point = CGPoint(x: 210, y: 400)
    private let targetFrame = CGRect(x: 60, y: 90, width: 776, height: 650)

    // Break: first-covering Quartz order rejects a target even though the native
    // input hit explicitly identifies it through an input-transparent overlay.
    func testNativeTargetHitAllowsCoveringInputTransparentWindowBeforeTarget() {
        let rows = [
            Window(id: 9, ownerPID: 700, frame: CGRect(x: 0, y: 0, width: 1470, height: 956), alpha: 1),
            target()
        ]
        XCTAssertEqual(resolve(hit: 11496, windows: rows), 11496)
    }

    // Break: blanket exclusion of the preceding window admits scrolling even
    // when that other app is the actual native input recipient.
    func testActualOtherAppHitRejectsUnderlyingTarget() {
        let rows = [
            Window(id: 9, ownerPID: 700, frame: CGRect(x: 0, y: 0, width: 1470, height: 956), alpha: 1),
            target()
        ]
        XCTAssertNil(resolve(hit: 9, windows: rows))
    }

    // Break: accepting owner PID alone sends events to a different window in
    // the same app instead of the exact AX window selected for scrolling.
    func testActualOtherWindowOfSameAppRejectsUnderlyingAXWindow() {
        let rows = [
            Window(id: 11497, ownerPID: 3962, frame: CGRect(x: 100, y: 200, width: 500, height: 500), alpha: 1),
            target()
        ]
        XCTAssertNil(resolve(hit: 11497, windows: rows))
    }

    // Break: requiring a convenient Quartz order rather than the bound native
    // hit fails valid targets whenever unrelated rows are reordered.
    func testExactNativeTargetHitIsIndependentOfUnrelatedRowOrder() {
        let other = Window(id: 88, ownerPID: 800, frame: CGRect(x: 1000, y: 10, width: 100, height: 100), alpha: 1)
        XCTAssertEqual(resolve(hit: 11496, windows: [target(), other]), 11496)
        XCTAssertEqual(resolve(hit: 11496, windows: [other, target()]), 11496)
        XCTAssertEqual(resolve(hit: 11496, windows: [target(alpha: 0.5)]), 11496)
    }

    // Break: converting an unknown/signed/out-of-range native window number by
    // truncation or falling back to a geometrically matching Quartz row.
    func testUnknownNegativeOverflowAndAbsentNativeHitIDsAreRejected() {
        for hit in [0, -1, Int.min, 4_294_967_296, Int.max, 55555] {
            XCTAssertNil(resolve(hit: hit, windows: [target()]), "Unexpected admission for hit \(hit)")
        }
        XCTAssertNil(resolve(hit: 11496, windows: []))
    }

    // Break: imposing a signed 32-bit limit rejects an otherwise representable
    // public CGWindowID at its valid upper boundary.
    func testLargestRepresentableWindowIDCanBindExactly() {
        XCTAssertEqual(resolve(hit: 4_294_967_295,
            windows: [target(id: 4_294_967_295)]), CGWindowID(4_294_967_295))
    }

    // Break: selecting by rectangle alone ignores the native hit window ID.
    func testMatchingOwnerAndFrameCannotSubstituteDifferentWindowID() {
        XCTAssertNil(resolve(hit: 11496, windows: [target(id: 12345)]))
    }

    // Break: a matching native ID from a different process is accepted using
    // only its geometry; or invalid AX owner values become valid identities.
    func testHitRowMustBelongToThePositiveAXOwnerPID() {
        XCTAssertNil(resolve(hit: 11496, windows: [target(owner: 700)]))
        let invalidOwners: [pid_t] = [0, -1]
        for owner in invalidOwners {
            XCTAssertNil(ScrollTargetWindowPolicy.resolve(point: point, ownerPID: owner,
                axWindowFrame: targetFrame, mouseHitWindowNumber: 11496,
                windows: [target(owner: owner)]))
        }
    }

    // Break: tolerating moved/resized window geometry admits a stale AX/Quartz
    // pairing. The click remains inside each row, so containment is insufficient.
    func testHitRowMustExactlyMatchTheAXWindowFrame() {
        let wrongFrames = [
            CGRect(x: 61, y: 90, width: 776, height: 650),
            CGRect(x: 60, y: 91, width: 776, height: 650),
            CGRect(x: 60, y: 90, width: 777, height: 650),
            CGRect(x: 60, y: 90, width: 776, height: 651)
        ]
        for frame in wrongFrames {
            XCTAssertNil(resolve(hit: 11496, windows: [target(frame: frame)]), "Mismatched frame \(frame)")
        }
    }

    // Break: checking ID/owner but never verifying that the queried point is
    // actually inside the bound AX/native window.
    func testPointOutsideBoundWindowIsRejected() {
        for outside in [CGPoint(x: 59, y: 400), CGPoint(x: 210, y: 89),
                        CGPoint(x: 837, y: 400), CGPoint(x: 210, y: 741)] {
            XCTAssertNil(ScrollTargetWindowPolicy.resolve(point: outside, ownerPID: 3962,
                axWindowFrame: targetFrame, mouseHitWindowNumber: 11496, windows: [target()]))
        }
    }

    // Break: resolving the first duplicate native-ID row hides ambiguous or
    // contradictory system metadata. Even identical duplicates are ambiguous.
    func testDuplicateHitRowsAreRejectedRegardlessOfWhichRowWouldMatch() {
        XCTAssertNil(resolve(hit: 11496, windows: [target(), target()]))
        XCTAssertNil(resolve(hit: 11496, windows: [target(), target(owner: 700)]))
        XCTAssertNil(resolve(hit: 11496, windows: [target(owner: 700), target()]))
        XCTAssertNil(resolve(hit: 11496, windows: [target(alpha: 0), target()]))
    }

    // Break: a native hit ID chooses between two coincident windows although
    // AX has supplied only owner/frame, not a public binding to either ID.
    func testDistinctWindowIDsSharingAXOwnerAndExactFrameAreAmbiguous() {
        XCTAssertNil(resolve(hit: 11496, windows: [target(), target(id: 11497)]))
        XCTAssertNil(resolve(hit: 11496, windows: [target(id: 11497), target()]))
        XCTAssertNil(resolve(hit: 11497, windows: [target(), target(id: 11497)]))
    }

    // Break: NaN comparisons or permissive alpha defaults admit a non-visible
    // or malformed target. Alpha of other unrelated rows is not the authority.
    func testInvisibleOrInvalidTargetAlphaIsRejected() {
        for alpha in [0, -0.1, 1.1, Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertNil(resolve(hit: 11496, windows: [target(alpha: alpha)]), "Invalid alpha \(alpha)")
        }
    }

    // Break: nonfinite input slips through comparison/CGRect behavior and is
    // turned into an apparently valid native target.
    func testNonfiniteTargetPointsAreRejected() {
        for invalid in [CGPoint(x: CGFloat.nan, y: 400), CGPoint(x: 210, y: CGFloat.nan),
                        CGPoint(x: CGFloat.infinity, y: 400), CGPoint(x: 210, y: -CGFloat.infinity)] {
            XCTAssertNil(ScrollTargetWindowPolicy.resolve(point: invalid, ownerPID: 3962,
                axWindowFrame: targetFrame, mouseHitWindowNumber: 11496, windows: [target()]))
        }
    }

    // Break: standardized negative rectangles, null/infinite frames or overflow
    // are accepted when AX and Quartz happen to repeat the same malformed data.
    func testMalformedMatchingAXAndNativeFramesAreRejected() {
        let invalidFrames = [
            CGRect.zero, CGRect.null, CGRect.infinite,
            CGRect(x: 60, y: 90, width: 0, height: 650),
            CGRect(x: 60, y: 90, width: 776, height: 0),
            CGRect(x: 836, y: 90, width: -776, height: 650),
            CGRect(x: 60, y: 740, width: 776, height: -650),
            CGRect(x: CGFloat.nan, y: 90, width: 776, height: 650),
            CGRect(x: 60, y: CGFloat.infinity, width: 776, height: 650),
            CGRect(x: 60, y: 90, width: CGFloat.infinity, height: 650),
            CGRect(x: 60, y: 90, width: 776, height: CGFloat.nan),
            CGRect(x: CGFloat.greatestFiniteMagnitude, y: 90, width: CGFloat.greatestFiniteMagnitude, height: 650)
        ]
        for frame in invalidFrames {
            XCTAssertNil(ScrollTargetWindowPolicy.resolve(point: point, ownerPID: 3962,
                axWindowFrame: frame, mouseHitWindowNumber: 11496, windows: [target(frame: frame)]),
                "Malformed matching frames must not become a target: \(frame)")
        }
    }

    // Break: forcing all global coordinates into the primary display excludes
    // valid target windows on a display to its left or above.
    func testNegativeGlobalTargetCoordinatesRemainValidWhenBoundExactly() {
        XCTAssertEqual(ScrollTargetWindowPolicy.resolve(point: CGPoint(x: -210, y: -400), ownerPID: 3962,
            axWindowFrame: CGRect(x: -500, y: -600, width: 400, height: 300), mouseHitWindowNumber: 11496,
            windows: [target(frame: CGRect(x: -500, y: -600, width: 400, height: 300))]), 11496)
    }

    // Break: forgetting the global vertical flip asks AppKit about the wrong
    // window even while Quartz/AX agree at (210,400).
    func testQuartzPointMapsToLiteralAppKitPointUsingPrimaryScreenTop() {
        XCTAssertEqual(ScrollTargetWindowPolicy.appKitPoint(fromQuartz: CGPoint(x: 210, y: 400),
            primaryScreenFrame: CGRect(x: 0, y: 0, width: 1470, height: 956)), CGPoint(x: 210, y: 556))
    }

    // Break: clamping to the primary screen, flipping X, or using a secondary
    // display's height corrupts native hit testing in the global coordinate space.
    func testCoordinateConversionPreservesSecondaryDisplayGlobalCoordinates() {
        let cases: [(CGPoint, CGPoint)] = [
            (CGPoint(x: -210, y: 400), CGPoint(x: -210, y: 556)),
            (CGPoint(x: 1500, y: -200), CGPoint(x: 1500, y: 1156)),
            (CGPoint(x: 210, y: 1000), CGPoint(x: 210, y: -44)),
            (CGPoint(x: 210, y: 0), CGPoint(x: 210, y: 956))
        ]
        for (input, expected) in cases {
            XCTAssertEqual(ScrollTargetWindowPolicy.appKitPoint(fromQuartz: input,
                primaryScreenFrame: CGRect(x: 0, y: 0, width: 1470, height: 956)), expected)
        }
    }

    // Break: conversion manufactures an AppKit point from NaN/infinity.
    func testCoordinateConversionRejectsNonfiniteInputPoints() {
        for invalid in [CGPoint(x: CGFloat.nan, y: 400), CGPoint(x: 210, y: CGFloat.nan),
                        CGPoint(x: CGFloat.infinity, y: 400), CGPoint(x: 210, y: -CGFloat.infinity)] {
            XCTAssertNil(ScrollTargetWindowPolicy.appKitPoint(fromQuartz: invalid,
                primaryScreenFrame: CGRect(x: 0, y: 0, width: 1470, height: 956)))
        }
    }

    // Break: deriving a flip origin from malformed primary-display geometry
    // yields a plausible but unrelated input target.
    func testCoordinateConversionRejectsInvalidPrimaryScreenFrames() {
        let invalidFrames = [
            CGRect.zero, CGRect.null, CGRect.infinite,
            CGRect(x: 0, y: 0, width: -1470, height: 956),
            CGRect(x: 0, y: 0, width: 1470, height: -956),
            CGRect(x: CGFloat.nan, y: 0, width: 1470, height: 956),
            CGRect(x: 0, y: CGFloat.infinity, width: 1470, height: 956),
            CGRect(x: 0, y: 0, width: CGFloat.nan, height: 956),
            CGRect(x: 0, y: 0, width: 1470, height: CGFloat.infinity),
            CGRect(x: 0, y: CGFloat.greatestFiniteMagnitude, width: 1470, height: CGFloat.greatestFiniteMagnitude)
        ]
        for frame in invalidFrames {
            XCTAssertNil(ScrollTargetWindowPolicy.appKitPoint(fromQuartz: CGPoint(x: 210, y: 400), primaryScreenFrame: frame))
        }
    }

    // Break: two individually finite operands overflow while computing the
    // global flipped Y, producing infinity as an authorized mouse-hit point.
    func testCoordinateConversionRejectsArithmeticOverflow() {
        XCTAssertNil(ScrollTargetWindowPolicy.appKitPoint(fromQuartz: CGPoint(x: 0, y: -CGFloat.greatestFiniteMagnitude),
            primaryScreenFrame: CGRect(x: 0, y: 0, width: 1470, height: CGFloat.greatestFiniteMagnitude)))
    }

    private func target(id: CGWindowID = 11496, owner: pid_t = 3962, frame: CGRect? = nil, alpha: Double = 1) -> Window {
        Window(id: id, ownerPID: owner, frame: frame ?? targetFrame, alpha: alpha)
    }

    private func resolve(hit: Int, windows: [Window]) -> CGWindowID? {
        ScrollTargetWindowPolicy.resolve(point: point, ownerPID: 3962,
            axWindowFrame: targetFrame, mouseHitWindowNumber: hit, windows: windows)
    }
}
