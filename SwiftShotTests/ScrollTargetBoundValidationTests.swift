import AppKit
import ApplicationServices
import XCTest
@testable import SwiftShot

/// Real metadata parsing, bound admission, and retained-identity comparison.
/// Literal rows and input observations stand in only for external OS data.
/// AX objects below are opaque synthetic handles: no AX queries, windows,
/// screen capture, event posting, or live-resolver coverage is claimed here.
@MainActor
final class ScrollTargetBoundValidationTests: XCTestCase {
    private typealias Window = ScrollTargetWindowPolicy.Window
    private typealias Input = ScrollTargetWindowPolicy.InputObservation

    // Break: parser defaults/replaces metadata rather than preserving the bound row.
    func testExactOnScreenMetadataParsesAndAdmitsOriginalWindow() throws {
        let parsed = try XCTUnwrap(ScrollTargetWindowMetadata.parseBound([row()], windowID: 417))
        XCTAssertEqual(parsed.id, 417)
        XCTAssertEqual(parsed.ownerPID, 701)
        XCTAssertEqual(parsed.frame, CGRect(x: 10, y: 20, width: 300, height: 200))
        XCTAssertEqual(parsed.alpha, 1)
        XCTAssertTrue(parsed.isOnScreen)
        XCTAssertEqual(resolve(parsed), 417)
    }

    // Break: first-row selection hides absent, duplicate, or unexpectedly broad results.
    func testMetadataMustContainExactlyOneRow() {
        for rows in [[], [row(), row()], [row(), row(id: 418)], [row(id: 418), row()]] {
            XCTAssertNil(ScrollTargetWindowMetadata.parseBound(rows, windowID: 417))
        }
    }

    // Break: a missing admission field silently receives a permissive default.
    func testMissingRequiredMetadataNeverDefaultsToAnAdmissibleWindow() {
        for key in [kCGWindowNumber, kCGWindowOwnerPID, kCGWindowBounds, kCGWindowAlpha, kCGWindowIsOnscreen] {
            var candidate = row()
            candidate.removeValue(forKey: key as String)
            XCTAssertNil(ScrollTargetWindowMetadata.parseBound([candidate], windowID: 417), "Missing \(key)")
        }
    }

    // Break: truncating/wrapping an ID manufactures the requested window number.
    func testWrongMalformedFractionalAndOverflowWindowIDsAreRejected() {
        let values: [Any] = [418, 0, -1, 417.25, 4_294_967_713 as Int64, "417", NSNull()]
        for value in values {
            var candidate = row()
            candidate[kCGWindowNumber as String] = value
            XCTAssertNil(ScrollTargetWindowMetadata.parseBound([candidate], windowID: 417), "ID \(value)")
        }
        XCTAssertNil(ScrollTargetWindowMetadata.parseBound([row(id: 0)], windowID: 0))
        var booleanID = row(id: 1)
        booleanID[kCGWindowNumber as String] = true
        XCTAssertNil(ScrollTargetWindowMetadata.parseBound([booleanID], windowID: 1))
    }

    // Break: signed/fractional/Boolean owner coercion turns malformed metadata into a PID.
    func testMalformedOwnerPIDsAreRejectedByParser() {
        let values: [Any] = [0, -1, 701.25, 4_294_967_997 as Int64, true, "701", NSNull()]
        for value in values {
            var candidate = row()
            candidate[kCGWindowOwnerPID as String] = value
            XCTAssertNil(ScrollTargetWindowMetadata.parseBound([candidate], windowID: 417), "PID \(value)")
        }
    }

    // Break: invalid/missing geometry survives parsing as a usable native frame.
    func testMalformedNonfiniteAndNonpositiveMetadataFramesAreRejected() {
        let values: [Any] = [
            NSNull(), "10,20,300,200", ["X": 10, "Y": 20, "Width": 300],
            ["X": Double.nan, "Y": 20, "Width": 300, "Height": 200],
            ["X": 10, "Y": Double.infinity, "Width": 300, "Height": 200],
            ["X": 10, "Y": 20, "Width": 0, "Height": 200],
            ["X": 10, "Y": 20, "Width": 300, "Height": -1]
        ]
        for value in values {
            var candidate = row()
            candidate[kCGWindowBounds as String] = value
            XCTAssertNil(ScrollTargetWindowMetadata.parseBound([candidate], windowID: 417))
        }
    }

    // Break: invisible or invalid alpha is accepted through a default or coercion.
    func testInvalidMetadataAlphaIsRejected() {
        let values: [Any] = [0, -0.1, 1.1, Double.nan, Double.infinity, true, "1", NSNull()]
        for value in values {
            var candidate = row()
            candidate[kCGWindowAlpha as String] = value
            XCTAssertNil(ScrollTargetWindowMetadata.parseBound([candidate], windowID: 417), "Alpha \(value)")
        }
    }

    // Break: including-window metadata is mistaken for evidence the window is onscreen.
    func testOffScreenAndMalformedOnScreenMetadataAreRejected() {
        let values: [Any] = [false, NSNull(), "true", 0, 1, 2]
        for value in values {
            var candidate = row()
            candidate[kCGWindowIsOnscreen as String] = value
            XCTAssertNil(ScrollTargetWindowMetadata.parseBound([candidate], windowID: 417))
        }
    }

    // Break: a signed 32-bit restriction rejects a valid public CGWindowID.
    func testLargestPublicWindowIDIsPreservedExactly() throws {
        let parsed = try XCTUnwrap(ScrollTargetWindowMetadata.parseBound([row(id: UInt32.max)], windowID: UInt32.max))
        XCTAssertEqual(parsed.id, 4_294_967_295)
        XCTAssertEqual(ScrollTargetWindowPolicy.resolveBoundStable(point: CGPoint(x: 50, y: 60),
            ownerPID: 701, axWindowFrame: CGRect(x: 10, y: 20, width: 300, height: 200),
            windowID: UInt32.max, window: parsed,
            readCurrentInput: { Input(windowNumber: 4_294_967_295, foregroundPID: 701) }), UInt32.max)
    }

    // Break: legitimate negative display coordinates or partial opacity are discarded.
    func testFiniteNegativeOriginAndPartialOpacityRemainAdmissible() throws {
        var candidate = row()
        candidate[kCGWindowBounds as String] = ["X": -310, "Y": -220, "Width": 300, "Height": 200]
        candidate[kCGWindowAlpha as String] = 0.5
        let parsed = try XCTUnwrap(ScrollTargetWindowMetadata.parseBound([candidate], windowID: 417))
        XCTAssertEqual(ScrollTargetWindowPolicy.resolveBoundStable(point: CGPoint(x: -200, y: -100),
            ownerPID: 701, axWindowFrame: CGRect(x: -310, y: -220, width: 300, height: 200),
            windowID: 417, window: parsed,
            readCurrentInput: { Input(windowNumber: 417, foregroundPID: 701) }), 417)
    }

    // Break: bound validation always rejects or substitutes an unrelated native ID.
    func testStableBoundWindowAndForegroundReturnTheOriginalID() {
        XCTAssertEqual(resolve(window()), 417)
    }

    // Break: a matching owner/frame can replace the stored CGWindowID.
    func testDifferentMetadataWindowIDCannotReplaceOriginalBinding() {
        XCTAssertNil(resolve(window(id: 418)))
        XCTAssertNil(resolve(window(id: 418), first: Input(windowNumber: 418, foregroundPID: 701),
            final: Input(windowNumber: 418, foregroundPID: 701)),
            "Even internally consistent replacement metadata and native hits must not change the immutable binding")
    }

    // Break: a reused CGWindowID is accepted despite a different positive owner PID.
    func testReusedWindowIDUnderForeignOwnerCannotValidateOriginalBinding() throws {
        var candidate = row()
        candidate[kCGWindowOwnerPID as String] = 702
        let parsed = try XCTUnwrap(ScrollTargetWindowMetadata.parseBound([candidate], windowID: 417))
        XCTAssertEqual(parsed.ownerPID, 702)
        XCTAssertNil(resolve(parsed))
    }

    // Break: containment replaces exact frame equality for a moved/resized target.
    func testChangedBoundWindowFrameRejectsEvenWhilePointRemainsInside() {
        for frame in [CGRect(x: 11, y: 20, width: 300, height: 200),
                      CGRect(x: 10, y: 20, width: 301, height: 200)] {
            XCTAssertNil(resolve(window(frame: frame)))
        }
    }

    // Break: direct policy callers can bypass the onscreen requirement.
    func testOffScreenBoundWindowIsRejectedEvenWithMatchingNativeObservations() {
        XCTAssertNil(resolve(window(onScreen: false)))
    }

    // Break: the bound shortcut omits the original geometry/alpha admission checks.
    func testBoundPolicyRetainsFiniteFrameAndVisibleAlphaChecks() {
        for alpha in [0, -1, 1.1, Double.nan, Double.infinity] {
            XCTAssertNil(resolve(window(alpha: alpha)))
        }
        XCTAssertNil(resolve(window(frame: CGRect(x: 10, y: 20, width: 0, height: 200))))
        XCTAssertNil(resolve(window(frame: CGRect(x: CGFloat.infinity, y: 20, width: 300, height: 200))))
    }

    // Break: either native read can retarget to a same-process replacement window.
    func testSameProcessReplacementAtEitherNativeReadRejectsOriginalBinding() {
        XCTAssertNil(resolve(window(), first: Input(windowNumber: 418, foregroundPID: 701)))
        XCTAssertNil(resolve(window(), final: Input(windowNumber: 418, foregroundPID: 701)))
    }

    // Break: unavailable or nonrepresentable native hits reuse the stored valid ID.
    func testMissingAndInvalidNativeHitsAtEitherReadAreNotRepaired() {
        for id in [0, -1, Int.max] {
            XCTAssertNil(resolve(window(), first: Input(windowNumber: id, foregroundPID: 701)))
            XCTAssertNil(resolve(window(), final: Input(windowNumber: id, foregroundPID: 701)))
        }
    }

    // Break: a changed/missing foreground owner is ignored by the bound shortcut.
    func testForeignOrUnavailableForegroundAtEitherReadRejectsBinding() {
        let owners: [pid_t?] = [702, nil]
        for pid in owners {
            XCTAssertNil(resolve(window(), first: Input(windowNumber: 417, foregroundPID: pid)))
            XCTAssertNil(resolve(window(), final: Input(windowNumber: 417, foregroundPID: pid)))
        }
    }

    // Break: optimizing bound revalidation accidentally weakens initial ambiguity refusal.
    func testInitialBindingStillRejectsCoincidentSameOwnerWindows() {
        XCTAssertNil(ScrollTargetWindowPolicy.resolveStable(point: CGPoint(x: 50, y: 60),
            ownerPID: 701, axWindowFrame: CGRect(x: 10, y: 20, width: 300, height: 200),
            windows: [window(), window(id: 418)],
            readCurrentInput: { Input(windowNumber: 417, foregroundPID: 701) }))
    }

    // Break: pointer/reference identity replaces CFEqual for retained AX objects.
    func testEquivalentSyntheticAXHandlesPreserveRetainedIdentity() {
        let original = identity()
        let equivalent = identity()
        XCTAssertTrue(original.matches(equivalent))
    }

    // Break: bound identity silently refreshes PID, window number, or geometry.
    func testRetainedIdentityRejectsChangedMetadataWithSameAXHandles() {
        let original = identity()
        let replacements = [
            identity(pid: 702, window: original.window, scroll: original.scrollArea),
            identity(id: 418, window: original.window, scroll: original.scrollArea),
            identity(windowFrame: CGRect(x: 11, y: 20, width: 300, height: 200), window: original.window, scroll: original.scrollArea),
            identity(scrollFrame: CGRect(x: 21, y: 40, width: 200, height: 150), window: original.window, scroll: original.scrollArea)
        ]
        for replacement in replacements { XCTAssertFalse(original.matches(replacement)) }
    }

    // Break: same owner/window/frames hide replacement of the AX window itself.
    func testRetainedIdentityRejectsChangedAXWindowWithIdenticalMetadata() {
        let original = identity()
        XCTAssertFalse(original.matches(identity(window: AXUIElementCreateApplication(703), scroll: original.scrollArea)))
    }

    // Break: a new scroll area inside the same native window is treated as the old target.
    func testRetainedIdentityRejectsChangedAXScrollAreaWithIdenticalMetadata() {
        let original = identity()
        XCTAssertFalse(original.matches(identity(window: original.window, scroll: AXUIElementCreateApplication(704))))
    }

    private func row(id: CGWindowID = 417) -> [String: Any] {
        [kCGWindowNumber as String: id, kCGWindowOwnerPID as String: 701,
         kCGWindowBounds as String: ["X": 10, "Y": 20, "Width": 300, "Height": 200],
         kCGWindowAlpha as String: 1.0, kCGWindowIsOnscreen as String: true,
         kCGWindowLayer as String: 0, kCGWindowSharingState as String: 1,
         kCGWindowStoreType as String: 2, kCGWindowMemoryUsage as String: 1_048_576]
    }

    private func window(id: CGWindowID = 417, owner: pid_t = 701,
                        frame: CGRect = CGRect(x: 10, y: 20, width: 300, height: 200),
                        alpha: Double = 1, onScreen: Bool = true) -> Window {
        var result = Window(id: id, ownerPID: owner, frame: frame, alpha: alpha)
        result.isOnScreen = onScreen
        return result
    }

    private func resolve(_ window: Window,
                         first: Input = Input(windowNumber: 417, foregroundPID: 701),
                         final: Input = Input(windowNumber: 417, foregroundPID: 701)) -> CGWindowID? {
        var read = 0
        return ScrollTargetWindowPolicy.resolveBoundStable(point: CGPoint(x: 50, y: 60),
            ownerPID: 701, axWindowFrame: CGRect(x: 10, y: 20, width: 300, height: 200),
            windowID: 417, window: window, readCurrentInput: {
                defer { read += 1 }
                return read == 0 ? first : final
            })
    }

    private func identity(pid: pid_t = 701, id: CGWindowID = 417,
                          windowFrame: CGRect = CGRect(x: 10, y: 20, width: 300, height: 200),
                          scrollFrame: CGRect = CGRect(x: 20, y: 40, width: 200, height: 150),
                          window: AXUIElement? = nil, scroll: AXUIElement? = nil) -> ScrollTargetIdentity {
        // Creating references does not contact or launch these arbitrary PIDs.
        // Their roles/AX ownership are not asserted: only stored-handle comparison is under test.
        ScrollTargetIdentity(pid: pid, windowID: id, windowFrame: windowFrame, scrollFrame: scrollFrame,
            window: window ?? AXUIElementCreateApplication(701),
            scrollArea: scroll ?? AXUIElementCreateApplication(702))
    }
}
