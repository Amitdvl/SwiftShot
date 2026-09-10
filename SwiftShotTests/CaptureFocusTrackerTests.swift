import XCTest
import AppKit
@testable import SwiftShot

@MainActor
final class CaptureFocusTrackerTests: XCTestCase {
    // Returning remembered history first would restore the wrong app when the
    // user starts a capture from a different foreground application.
    func testCurrentExternalApplicationWinsOverRememberedApplication() {
        var history = CaptureFocusHistory<FocusTestApplication>(ownPID: 10)
        let previous = FocusTestApplication(pid: 20)
        let current = FocusTestApplication(pid: 30)
        history.record(previous)
        XCTAssertTrue(history.destination(frontmost: current) === current)
    }

    // SwiftShot's Settings/history activation must not overwrite the return app.
    func testOwnApplicationActivationPreservesPreviousExternalDestination() {
        var history = CaptureFocusHistory<FocusTestApplication>(ownPID: 10)
        let external = FocusTestApplication(pid: 20)
        let own = FocusTestApplication(pid: 10)
        history.record(external)
        history.record(own)
        XCTAssertTrue(history.destination(frontmost: own) === external)
    }

    // Menu-bar helpers and background agents are not regular return targets.
    func testNonRegularApplicationsDoNotReplaceExternalDestination() {
        var history = CaptureFocusHistory<FocusTestApplication>(ownPID: 10)
        let external = FocusTestApplication(pid: 20)
        history.record(external)
        for policy in [NSApplication.ActivationPolicy.accessory, .prohibited] {
            let helper = FocusTestApplication(pid: 30, policy: policy)
            history.record(helper)
            XCTAssertTrue(history.destination(frontmost: helper) === external)
        }
    }

    // Delayed termination/activation observations cannot poison a live fallback.
    func testTerminatedAndInvalidPIDApplicationsAreIgnored() {
        var history = CaptureFocusHistory<FocusTestApplication>(ownPID: 10)
        let external = FocusTestApplication(pid: 20)
        history.record(external)
        for ineligible in [FocusTestApplication(pid: 30, terminated: true),
                           FocusTestApplication(pid: 0), FocusTestApplication(pid: -1)] {
            history.record(ineligible)
            XCTAssertTrue(history.destination(frontmost: ineligible) === external)
        }
    }

    // Eligibility is rechecked at use time, not only when activation was seen.
    func testRememberedApplicationThatTerminatesIsNotReturned() {
        var history = CaptureFocusHistory<FocusTestApplication>(ownPID: 10)
        let external = FocusTestApplication(pid: 20)
        history.record(external)
        external.isTerminated = true
        XCTAssertNil(history.destination(frontmost: FocusTestApplication(pid: 10)))
    }

    func testRememberedApplicationThatBecomesAccessoryIsNotReturned() {
        var history = CaptureFocusHistory<FocusTestApplication>(ownPID: 10)
        let external = FocusTestApplication(pid: 20)
        history.record(external)
        external.activationPolicy = .accessory
        XCTAssertNil(history.destination(frontmost: nil))
    }

    // Keep only the latest eligible activation, without a growing app history.
    func testLatestEligibleActivationReplacesEarlierDestination() {
        var history = CaptureFocusHistory<FocusTestApplication>(ownPID: 10)
        let earlier = FocusTestApplication(pid: 20)
        let latest = FocusTestApplication(pid: 30)
        history.record(earlier)
        history.record(latest)
        history.record(nil)
        XCTAssertTrue(history.destination(frontmost: nil) === latest)
    }

    func testNoEligibleHistoryDoesNotInventDestination() {
        var history = CaptureFocusHistory<FocusTestApplication>(ownPID: 10)
        history.record(FocusTestApplication(pid: 10))
        history.record(FocusTestApplication(pid: 20, policy: .accessory))
        XCTAssertNil(history.destination(frontmost: nil))
        XCTAssertNil(history.destination(frontmost: FocusTestApplication(pid: 10)))
    }
}

/// The production policy is real; only OS-owned application state is replaced.
@MainActor
private final class FocusTestApplication: CaptureFocusApplication {
    let processIdentifier: pid_t
    var isTerminated: Bool
    var activationPolicy: NSApplication.ActivationPolicy

    init(pid: pid_t, policy: NSApplication.ActivationPolicy = .regular, terminated: Bool = false) {
        processIdentifier = pid
        activationPolicy = policy
        isTerminated = terminated
    }
}
