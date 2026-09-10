import CoreGraphics
import XCTest
@testable import SwiftShot

final class ScrollTargetRevalidationTests: XCTestCase {
    private typealias Input = ScrollTargetWindowPolicy.InputObservation

    // Break: a resolver accepts its initial window even though another window
    // in the same owner process became the native input target before return.
    func testChangedSameProcessWindowAtFinalReadRejectsInitialTarget() {
        let result = resolve(first: Input(windowNumber: 417, foregroundPID: 701),
            final: Input(windowNumber: 418, foregroundPID: 701))
        XCTAssertNil(result,
            "Matching PID cannot authorize a different final native window")
    }

    // Break: a resolver checks window identity but ignores a foreground change
    // during its AX/Quartz work, allowing input to a now-background app.
    func testForeignForegroundAtFinalReadRejectsInitialTarget() {
        let result = resolve(first: Input(windowNumber: 417, foregroundPID: 701),
            final: Input(windowNumber: 417, foregroundPID: 702))
        XCTAssertNil(result,
            "The final foreground owner must still be the selected owner")
    }

    // Break: loss of foreground information is treated as permission to retain
    // the previously valid target instead of failing closed.
    func testUnavailableForegroundAtFinalReadRejectsInitialTarget() {
        let result = resolve(first: Input(windowNumber: 417, foregroundPID: 701),
            final: Input(windowNumber: 417, foregroundPID: nil))
        XCTAssertNil(result,
            "Unavailable final foreground ownership is not a matching owner")
    }

    // Break: a final failed native hit lookup is replaced with the cached hit.
    func testMissingNativeWindowAtFinalReadRejectsInitialTarget() {
        let result = resolve(first: Input(windowNumber: 417, foregroundPID: 701),
            final: Input(windowNumber: 0, foregroundPID: 701))
        XCTAssertNil(result,
            "A missing final native hit must not reuse the initial window")
    }

    // Break: a resolver reacquires a later valid window after an invalid first
    // lookup, rather than requiring one identity across the whole resolution.
    func testInvalidFirstNativeWindowIsNotRescuedByLaterValidObservation() {
        let result = resolve(first: Input(windowNumber: 0, foregroundPID: 701),
            final: Input(windowNumber: 417, foregroundPID: 701))
        XCTAssertNil(result,
            "Later validity cannot repair an invalid initial native target")
    }

    // Break: only the final foreground is checked, silently repairing an
    // initially foreign hit-owner/foreground pairing.
    func testForeignFirstForegroundIsNotRescuedByLaterValidObservation() {
        let result = resolve(first: Input(windowNumber: 417, foregroundPID: 702),
            final: Input(windowNumber: 417, foregroundPID: 701))
        XCTAssertNil(result,
            "The initial observation must already belong to the selected foreground app")
    }

    // Break: a second read unconditionally rejects, or returns another row's ID
    // instead of the exact selected native window that stayed current.
    func testUnchangedExactWindowAndForegroundReturnsBoundNativeWindow() {
        let result = resolve(first: Input(windowNumber: 417, foregroundPID: 701),
            final: Input(windowNumber: 417, foregroundPID: 701))
        XCTAssertEqual(result, 417)
    }

    /// Only the changing native input boundary is supplied. Real production
    /// resolution consumes these observations and real candidate-window policy;
    /// assertions inspect its returned identity, never a mock's call count.
    private func resolve(first: Input, final: Input) -> CGWindowID? {
        let frame = CGRect(x: 10, y: 20, width: 300, height: 200)
        let windows = [
            ScrollTargetWindowPolicy.Window(id: 417, ownerPID: 701, frame: frame, alpha: 1),
            ScrollTargetWindowPolicy.Window(id: 418, ownerPID: 701,
                frame: CGRect(x: 30, y: 40, width: 100, height: 80), alpha: 1)
        ]
        var reads = 0
        return ScrollTargetWindowPolicy.resolveStable(point: CGPoint(x: 50, y: 60),
            ownerPID: 701, axWindowFrame: frame, windows: windows,
            readCurrentInput: {
                defer { reads += 1 }
                return reads == 0 ? first : final
            })
    }
}
