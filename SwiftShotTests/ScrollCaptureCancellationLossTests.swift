import AppKit
import ApplicationServices
import XCTest
@testable import SwiftShot

/// Real driver, single-use receipt, AX identity comparison and CGEvent delivery
/// constructor. Only native observations and the final OS effect sinks are fake.
@MainActor
final class ScrollCaptureCancellationLossTests: XCTestCase {
    // Break: cancellation is thrown before an observed failed identity is latched.
    func testCancelledFailedValidationCannotRestoreAfterIdentityReturns() async throws {
        try await checkLossDuringCancellation(purpose: .validation)
    }

    // Break: failed wheel admission loses its target-loss reason when cancellation wins.
    func testCancelledFailedWheelAdmissionCannotRestoreAfterIdentityReturns() async throws {
        try await checkLossDuringCancellation(purpose: .forwardScroll)
    }

    // Break: cancellation after metadata returns nil masks already observed bad metadata.
    func testCancelledBadMetadataCannotRestoreAfterMetadataReturns() async throws {
        try await checkLossDuringCancellation(purpose: .forwardScroll, badMetadata: true)
    }

    // Break: treating cancellation-only refusal as identity loss suppresses valid cleanup.
    func testCancellationWithStillValidIdentityPreservesGuardedCleanup() async throws {
        try await checkValidCancellation(duringMetadata: false)
    }

    // Break: every canceled metadata suspension is treated as a failed native authority.
    func testCancellationWithValidMetadataPreservesGuardedCleanup() async throws {
        try await checkValidCancellation(duringMetadata: true)
    }

    private func checkValidCancellation(duringMetadata: Bool) async throws {
        let environment = CancellationLossEnvironment()
        let driver = NativeScrollCaptureDriver(environment: environment)
        try await driver.begin(in: preparedTestRegion())
        try await driver.scrollDown(points: 80)
        driver.recordObservedMovement(points: 70)
        var work: Task<Void, Never>!
        let cancel: (NativeScrollCapturePurpose) -> Void = { purpose in
            if purpose == .validation { work.cancel() }
        }
        if duringMetadata { environment.beforeMetadataRead = cancel }
        else { environment.beforeIdentityCheck = cancel }
        work = Task { @MainActor in
            do { try await driver.validateTarget(); XCTFail("Cancelled validation must stop") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertTrue(Task.isCancelled)
            environment.beforeIdentityCheck = nil
            environment.beforeMetadataRead = nil
            _ = await driver.restore()
        }
        await work.value
        XCTAssertEqual(environment.events, [-80, 70])
        XCTAssertEqual(environment.pointerMoves, [CGPoint(x: 100, y: 100), CGPoint(x: 3, y: 4)])
        XCTAssertEqual(environment.focusRestorations, 1)
    }

    private func checkLossDuringCancellation(purpose: NativeScrollCapturePurpose, badMetadata: Bool = false) async throws {
        let environment = CancellationLossEnvironment()
        let driver = NativeScrollCaptureDriver(environment: environment)
        try await driver.begin(in: preparedTestRegion())
        try await driver.scrollDown(points: 80)
        driver.recordObservedMovement(points: 70)
        var work: Task<Void, Never>!
        let rejectAndCancel: (NativeScrollCapturePurpose) -> Void = { currentPurpose in
            guard currentPurpose == purpose else { return }
            if badMetadata { environment.metadataValid = false }
            else {
                let identity = environment.originalIdentity
                environment.currentIdentity = ScrollTargetIdentity(pid: identity.pid, windowID: identity.windowID,
                    windowFrame: identity.windowFrame, scrollFrame: identity.scrollFrame,
                    window: identity.window, scrollArea: AXUIElementCreateApplication(904))
            }
            work.cancel()
        }
        if badMetadata { environment.beforeMetadataRead = rejectAndCancel }
        else { environment.beforeIdentityCheck = rejectAndCancel }
        work = Task { @MainActor in
            do {
                if purpose == .validation { try await driver.validateTarget() }
                else { try await driver.scrollDown(points: 40) }
                XCTFail("Observed identity loss plus cancellation must stop the operation")
            } catch {}
            XCTAssertTrue(Task.isCancelled)
            // The original identity's return must not repair a loss already observed.
            environment.beforeIdentityCheck = nil
            environment.beforeMetadataRead = nil
            environment.metadataValid = true
            environment.currentIdentity = environment.originalIdentity
            _ = await driver.restore()
        }
        await work.value
        XCTAssertEqual(environment.events, [-80], "No reverse request after observed identity loss")
        XCTAssertEqual(environment.pointerMoves, [CGPoint(x: 100, y: 100)], "No restoring warp after loss")
        XCTAssertEqual(environment.focusRestorations, 0, "No focus restoration after loss")
    }
}

@MainActor
private final class CancellationLossEnvironment: NativeScrollCaptureEnvironment {
    let targetPoint = CGPoint(x: 100, y: 100)
    let originalIdentity: ScrollTargetIdentity
    var currentIdentity: ScrollTargetIdentity
    var beforeIdentityCheck: ((NativeScrollCapturePurpose) -> Void)?
    var beforeMetadataRead: ((NativeScrollCapturePurpose) -> Void)?
    var metadataValid = true
    private var pointer = CGPoint(x: 3, y: 4)
    private(set) var events: [Int32] = []
    private(set) var pointerMoves: [CGPoint] = []
    private(set) var focusRestorations = 0

    init() {
        // Opaque synthetic handles are only compared; no AX call queries these PIDs.
        let original = ScrollTargetIdentity(pid: 901, windowID: 719,
            windowFrame: CGRect(x: 10, y: 20, width: 300, height: 200),
            scrollFrame: CGRect(x: 20, y: 40, width: 200, height: 150),
            window: AXUIElementCreateApplication(901), scrollArea: AXUIElementCreateApplication(902))
        originalIdentity = original
        currentIdentity = original
    }

    func resolveTarget(in region: ScrollCaptureRegion) async throws -> NativeScrollCaptureTarget {
        let id = UUID()
        return NativeScrollCaptureTarget(id: id, point: targetPoint, ownerPID: originalIdentity.pid) { purpose in
            let metadata = ScrollTargetMetadataPreparation(now: { ContinuousClock.now }, read: { requestedID in
                self.beforeMetadataRead?(purpose)
                var row: [String: Any] = [kCGWindowNumber as String: 719, kCGWindowOwnerPID as String: 901,
                    kCGWindowBounds as String: ["X": 10, "Y": 20, "Width": 300, "Height": 200],
                    kCGWindowAlpha as String: 1.0, kCGWindowIsOnscreen as String: true,
                    kCGWindowLayer as String: 0, kCGWindowSharingState as String: 1,
                    kCGWindowStoreType as String: 2, kCGWindowMemoryUsage as String: 1_048_576]
                if !self.metadataValid { row.removeValue(forKey: kCGWindowIsOnscreen as String) }
                guard let requestedID,
                      let window = ScrollTargetWindowMetadata.parseBound([row], windowID: requestedID) else { return nil }
                return [window]
            })
            guard let snapshot = await metadata.prepare(boundTo: self.originalIdentity) else { return nil }
            return NativeScrollCaptureReceipt(targetID: id, point: self.targetPoint,
                ownerPID: self.originalIdentity.pid, purpose: purpose,
                deadline: snapshot.deadline, now: { ContinuousClock.now }, isCurrent: {
                    self.beforeIdentityCheck?(purpose)
                    return self.originalIdentity.matches(self.currentIdentity)
                })
        }
    }
    func hasAccess() -> Bool { true }
    func pointerLocation() -> CGPoint? { pointer }
    func movePointer(to point: CGPoint) -> Bool { pointerMoves.append(point); pointer = point; return true }
    func focusRestoration() -> @MainActor () -> Void { { self.focusRestorations += 1 } }
    func postWheel(_ delta: Int32, using receipt: NativeScrollCaptureReceipt, restoring: Bool) -> Bool {
        NativeScrollWheelDelivery(hasAccess: { true }, pointerLocation: { self.pointer },
            isCancelled: { Task.isCancelled }, dispatch: { event in
                self.events.append(Int32(NSEvent(cgEvent: event)!.scrollingDeltaY))
            }).post(delta, using: receipt, restoring: restoring)
    }
}
