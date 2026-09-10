import AppKit
import ApplicationServices
import XCTest
@testable import SwiftShot

/// Production driver, receipt admission, native-window policy, and final event
/// constructor are used together. Only native observations, the metadata I/O
/// boundary, and effect sinks are supplied. No system input is posted.
@MainActor
final class ScrollCaptureAsyncLifecycleTests: XCTestCase {
    // Break: metadata-first binding adopts a different foreground recipient after suspension.
    func testForegroundChangedDuringInitialMetadataCannotBindNewTargetOrCreateEffects() async {
        await assertInitialRecipientChangeIsRejected(ownerPID: 703, windowID: 419)
    }

    // Break: checking PID alone permits another window in that same process to become the target.
    func testSameProcessWindowChangedDuringInitialMetadataCannotBindNewTargetOrCreateEffects() async {
        await assertInitialRecipientChangeIsRejected(ownerPID: 701, windowID: 418)
    }

    private func assertInitialRecipientChangeIsRejected(ownerPID: pid_t, windowID: CGWindowID,
                                                      file: StaticString = #filePath, line: UInt = #line) async {
        let environment = PreparedDriverEnvironment()
        let gate = PreparedTestGate("Initial recipient metadata")
        defer { gate.release() }
        environment.initialMetadataGate = gate
        let driver = NativeScrollCaptureDriver(environment: environment)
        let work = Task { @MainActor in try await driver.begin(in: preparedTestRegion()) }
        await fulfillment(of: [gate.entered], timeout: 1)
        // The new recipient has internally consistent metadata, AX identity,
        // and native hit observations. Only the pre-await binding can reject it.
        let frame = CGRect(x: 11, y: 20, width: 300, height: 200)
        environment.currentIdentity = ScrollTargetIdentity(pid: ownerPID, windowID: windowID,
            windowFrame: frame, scrollFrame: environment.identity.scrollFrame,
            window: AXUIElementCreateApplication(ownerPID), scrollArea: AXUIElementCreateApplication(705))
        environment.initialInput = .init(windowNumber: Int(windowID), foregroundPID: ownerPID)
        environment.metadataRow[kCGWindowNumber as String] = windowID
        environment.metadataRow[kCGWindowOwnerPID as String] = ownerPID
        environment.metadataRow[kCGWindowBounds as String] = ["X": 11, "Y": 20, "Width": 300, "Height": 200]
        gate.release()
        await assertFailure(work, file: file, line: line)
        _ = await driver.restore()
        XCTAssertTrue(environment.pointerMoves.isEmpty, file: file, line: line)
        XCTAssertTrue(environment.events.isEmpty, file: file, line: line)
        XCTAssertEqual(environment.focusRestorations, 0, file: file, line: line)
    }

    // Break: initial metadata suspension loses the user's original pointer baseline.
    func testPointerMovedDuringInitialResolutionPreventsWarpAndCleanupEffects() async {
        let environment = PreparedDriverEnvironment()
        let gate = PreparedTestGate("Initial resolution")
        environment.resolutionGate = gate
        let driver = NativeScrollCaptureDriver(environment: environment)
        let work = Task { @MainActor in try await driver.begin(in: preparedTestRegion()) }
        await fulfillment(of: [gate.entered], timeout: 1)
        XCTAssertTrue(environment.pointerMoves.isEmpty)
        environment.pointer = CGPoint(x: 900, y: 700)
        gate.release()
        await assertFailure(work)
        _ = await driver.restore()
        XCTAssertTrue(environment.pointerMoves.isEmpty)
        XCTAssertTrue(environment.events.isEmpty)
        XCTAssertEqual(environment.focusRestorations, 0)
    }

    // Break: noncooperative native resolution returns after cancellation and still warps.
    func testCancellationDuringInitialResolutionCannotCreatePointerEffects() async {
        let environment = PreparedDriverEnvironment()
        let gate = PreparedTestGate("Cancelled initial resolution")
        environment.resolutionGate = gate
        let driver = NativeScrollCaptureDriver(environment: environment)
        let work = Task { @MainActor in try await driver.begin(in: preparedTestRegion()) }
        await fulfillment(of: [gate.entered], timeout: 1)
        work.cancel()
        gate.release()
        do { try await work.value; XCTFail("Cancelled resolution must stop begin") }
        catch { XCTAssertTrue(error is CancellationError) }
        _ = await driver.restore()
        XCTAssertTrue(environment.pointerMoves.isEmpty)
        XCTAssertTrue(environment.events.isEmpty)
        XCTAssertEqual(environment.focusRestorations, 0)
    }

    // Break: initial receipt preparation can move a pointer changed during its await.
    func testPointerMovedDuringInitialReceiptPreparationPreventsWarp() async {
        let environment = PreparedDriverEnvironment()
        let gate = PreparedTestGate("Initial pointer receipt")
        environment.gates[.initialPointerMove] = gate
        let driver = NativeScrollCaptureDriver(environment: environment)
        let work = Task { @MainActor in try await driver.begin(in: preparedTestRegion()) }
        await fulfillment(of: [gate.entered], timeout: 1)
        environment.pointer = CGPoint(x: 4, y: 4)
        gate.release()
        await assertFailure(work)
        _ = await driver.restore()
        XCTAssertTrue(environment.pointerMoves.isEmpty)
        XCTAssertEqual(environment.focusRestorations, 0)
    }

    // Break: a second begin replaces the lease while the first native request is pending.
    func testConcurrentBeginCannotReplacePendingOriginalTarget() async throws {
        let environment = PreparedDriverEnvironment()
        let gate = PreparedTestGate("Pending original target")
        defer { gate.release() }
        environment.resolutionGate = gate
        let driver = NativeScrollCaptureDriver(environment: environment)
        let first = Task { @MainActor in try await driver.begin(in: preparedTestRegion()) }
        await fulfillment(of: [gate.entered], timeout: 1)
        let rejected = expectation(description: "Second begin rejects without awaiting the occupied native gate")
        let second = Task { @MainActor in
            defer { rejected.fulfill() }
            try await driver.begin(in: preparedTestRegion())
        }
        await fulfillment(of: [rejected], timeout: 1)
        XCTAssertEqual(environment.resolutions, 1)
        gate.release()
        await assertFailure(second)
        try await first.value
        XCTAssertEqual(environment.pointerMoves, [environment.targetPoint])
        XCTAssertEqual(environment.purposes, [.initialPointerMove])
        _ = await driver.restore()
    }

    // Break: a pointer excursion observed while awaiting metadata is repaired by a later return.
    func testPointerLossDuringForwardPreparationLatchesAndSuppressesRestoration() async throws {
        let environment = PreparedDriverEnvironment()
        let driver = NativeScrollCaptureDriver(environment: environment)
        try await driver.begin(in: preparedTestRegion())
        let gate = PreparedTestGate("Forward metadata")
        environment.gates[.forwardScroll] = gate
        let work = Task { @MainActor in try await driver.scrollDown(points: 80) }
        await fulfillment(of: [gate.entered], timeout: 1)
        environment.pointer = CGPoint(x: 101, y: 100)
        gate.release()
        await assertFailure(work)
        environment.pointer = environment.targetPoint
        do { try await driver.validateTarget(); XCTFail("Observed loss remains latched") } catch {}
        _ = await driver.restore()
        XCTAssertTrue(environment.events.isEmpty)
        XCTAssertEqual(environment.pointerMoves, [environment.targetPoint])
        XCTAssertEqual(environment.focusRestorations, 0)
    }

    // Break: cancellation while noncooperative preparation waits is ignored when it returns.
    func testCancelledForwardPreparationCannotPostAfterItsLateReturn() async throws {
        let environment = PreparedDriverEnvironment()
        let driver = NativeScrollCaptureDriver(environment: environment)
        try await driver.begin(in: preparedTestRegion())
        let gate = PreparedTestGate("Cancelled forward metadata")
        environment.gates[.forwardScroll] = gate
        let work = Task { @MainActor in try await driver.scrollDown(points: 80) }
        await fulfillment(of: [gate.entered], timeout: 1)
        work.cancel()
        XCTAssertTrue(environment.events.isEmpty)
        gate.release()
        do { try await work.value; XCTFail("Cancellation must outlive the metadata await") }
        catch { XCTAssertTrue(error is CancellationError) }
        _ = await driver.restore()
        XCTAssertTrue(environment.events.isEmpty)
    }

    // Break: a fresh row authorizes a changed AX object in the original native window.
    func testChangedAXScrollAreaDuringPreparationPreventsForwardAndCleanup() async throws {
        let environment = PreparedDriverEnvironment()
        let driver = NativeScrollCaptureDriver(environment: environment)
        try await driver.begin(in: preparedTestRegion())
        let gate = PreparedTestGate("AX replacement")
        environment.gates[.forwardScroll] = gate
        let work = Task { @MainActor in try await driver.scrollDown(points: 80) }
        await fulfillment(of: [gate.entered], timeout: 1)
        let original = environment.identity
        environment.currentIdentity = ScrollTargetIdentity(pid: original.pid, windowID: original.windowID,
            windowFrame: original.windowFrame, scrollFrame: original.scrollFrame,
            window: original.window, scrollArea: AXUIElementCreateApplication(704))
        gate.release()
        await assertFailure(work)
        _ = await driver.restore()
        XCTAssertTrue(environment.events.isEmpty)
        XCTAssertEqual(environment.pointerMoves, [environment.targetPoint])
        XCTAssertEqual(environment.focusRestorations, 0)
    }

    // Break: receipt purpose, target generation, owner, or point can differ from the retained target.
    func testReceiptCannotReplaceRetainedGenerationPurposeOwnerOrPoint() async throws {
        for mutation in PreparedReceiptMutation.allCases {
            let environment = PreparedDriverEnvironment()
            let driver = NativeScrollCaptureDriver(environment: environment)
            try await driver.begin(in: preparedTestRegion())
            environment.receiptMutation = mutation
            do { try await driver.scrollDown(points: 80); XCTFail("Must reject \(mutation)") } catch {}
            _ = await driver.restore()
            XCTAssertTrue(environment.events.isEmpty, "Mutation \(mutation)")
            XCTAssertEqual(environment.pointerMoves, [environment.targetPoint])
            XCTAssertEqual(environment.focusRestorations, 0)
        }
    }

    // Break: bad/late metadata triggers reuse or retry before dispatch.
    func testBadAndLateMetadataAreTerminalWithoutAnotherRequest() async throws {
        for late in [false, true] {
            let environment = PreparedDriverEnvironment()
            let driver = NativeScrollCaptureDriver(environment: environment)
            try await driver.begin(in: preparedTestRegion())
            let before = environment.metadataReads
            if late { environment.metadataElapsed = .milliseconds(200) }
            else { environment.metadataRow.removeValue(forKey: kCGWindowIsOnscreen as String) }
            do { try await driver.scrollDown(points: 80); XCTFail("Bad metadata must stop Auto") } catch {}
            _ = await driver.restore()
            XCTAssertEqual(environment.metadataReads, before + 1, "No retry or cleanup query after metadata loss")
            XCTAssertTrue(environment.events.isEmpty)
            XCTAssertEqual(environment.pointerMoves, [environment.targetPoint])
            XCTAssertEqual(environment.focusRestorations, 0)
        }
    }

    // Break: repeated wheels reuse a receipt, or cleanup uses commanded rather than observed movement.
    func testEveryWheelUsesFreshReceiptAndObservedMovementRestoresExactlyOnce() async throws {
        let environment = PreparedDriverEnvironment()
        let driver = NativeScrollCaptureDriver(environment: environment)
        try await driver.begin(in: preparedTestRegion())
        try await driver.scrollDown(points: 80)
        driver.recordObservedMovement(points: 70)
        try await driver.scrollDown(points: 40)
        driver.recordObservedMovement(points: 35)
        let warning = await driver.restore()
        XCTAssertEqual(environment.events, [-80, -40, 105])
        XCTAssertEqual(environment.purposes.filter { $0 == .forwardScroll }.count, 2)
        XCTAssertEqual(environment.purposes.filter { $0 == .pageRestoration }.count, 1)
        XCTAssertEqual(environment.pointerMoves, [environment.targetPoint, environment.originalPoint])
        XCTAssertEqual(environment.focusRestorations, 1)
        XCTAssertTrue(warning?.contains("cannot be verified") == true)
    }

    // Break: cancellation after actual dispatch is checked before pending movement is recorded.
    func testCancellationInsideActualDispatchStillAccountsForPositiveCleanup() async throws {
        let environment = PreparedDriverEnvironment()
        let driver = NativeScrollCaptureDriver(environment: environment)
        try await driver.begin(in: preparedTestRegion())
        var work: Task<Void, Never>!
        environment.afterDispatch = { delta in if delta < 0 { work.cancel() } }
        work = Task { @MainActor in
            do { try await driver.scrollDown(points: 80) } catch {}
            XCTAssertTrue(Task.isCancelled)
            _ = await driver.restore()
        }
        await work.value
        XCTAssertEqual(environment.events, [-80, 80])
        XCTAssertEqual(environment.pointerMoves, [environment.targetPoint, environment.originalPoint])
        XCTAssertEqual(environment.focusRestorations, 1)
    }

    // Break: cleanup releases its lease or restores pointer/focus before asynchronous metadata returns.
    func testPendingRestorationRetainsOwnershipUntilAllEffectsFinish() async throws {
        let environment = PreparedDriverEnvironment()
        let driver = NativeScrollCaptureDriver(environment: environment)
        try await driver.begin(in: preparedTestRegion())
        try await driver.scrollDown(points: 80)
        driver.recordObservedMovement(points: 80)
        let gate = PreparedTestGate("Pending page restoration")
        defer { gate.release() }
        environment.gates[.pageRestoration] = gate
        let cleanup = Task { @MainActor in await driver.restore() }
        await fulfillment(of: [gate.entered], timeout: 1)
        let rejected = expectation(description: "Begin rejects while cleanup still owns native state")
        let next = Task { @MainActor in
            defer { rejected.fulfill() }
            try await driver.begin(in: preparedTestRegion())
        }
        await fulfillment(of: [rejected], timeout: 1)
        XCTAssertEqual(environment.events, [-80])
        XCTAssertEqual(environment.pointerMoves, [environment.targetPoint])
        XCTAssertEqual(environment.focusRestorations, 0)
        gate.release()
        await assertFailure(next)
        _ = await cleanup.value
        XCTAssertEqual(environment.events, [-80, 80])
        XCTAssertEqual(environment.focusRestorations, 1)
    }

    // Break: cancellation-time cleanup skips pointer revalidation after its await.
    func testPointerMovedDuringRestorationPreparationSuppressesRemainingEffects() async throws {
        let environment = PreparedDriverEnvironment()
        let driver = NativeScrollCaptureDriver(environment: environment)
        try await driver.begin(in: preparedTestRegion())
        try await driver.scrollDown(points: 80)
        driver.recordObservedMovement(points: 80)
        let gate = PreparedTestGate("Restoration pointer loss")
        environment.gates[.pageRestoration] = gate
        let cleanup = Task { @MainActor in await driver.restore() }
        await fulfillment(of: [gate.entered], timeout: 1)
        cleanup.cancel()
        environment.pointer = CGPoint(x: 700, y: 700)
        gate.release()
        _ = await cleanup.value
        XCTAssertEqual(environment.events, [-80])
        XCTAssertEqual(environment.pointerMoves, [environment.targetPoint])
        XCTAssertEqual(environment.focusRestorations, 0)
    }

    // Break: a successful reverse request grants later pointer/focus effects without new checks.
    func testTargetLossDuringPointerRestorationPreparationSuppressesWarpAndFocus() async throws {
        let environment = PreparedDriverEnvironment()
        let driver = NativeScrollCaptureDriver(environment: environment)
        try await driver.begin(in: preparedTestRegion())
        try await driver.scrollDown(points: 80)
        driver.recordObservedMovement(points: 80)
        let gate = PreparedTestGate("Pointer-restoration preparation")
        environment.gates[.pointerRestoration] = gate
        let cleanup = Task { @MainActor in await driver.restore() }
        await fulfillment(of: [gate.entered], timeout: 1)
        XCTAssertEqual(environment.events, [-80, 80])
        environment.displayIsCurrent = false
        gate.release()
        _ = await cleanup.value
        XCTAssertEqual(environment.pointerMoves, [environment.targetPoint])
        XCTAssertEqual(environment.focusRestorations, 0)
    }

    // Break: after restoring the pointer, a stale focus receipt can still steal focus.
    func testPointerLossDuringFocusPreparationSuppressesFocusOnly() async throws {
        let environment = PreparedDriverEnvironment()
        let driver = NativeScrollCaptureDriver(environment: environment)
        try await driver.begin(in: preparedTestRegion())
        let gate = PreparedTestGate("Focus-restoration preparation")
        environment.gates[.focusRestoration] = gate
        let cleanup = Task { @MainActor in await driver.restore() }
        await fulfillment(of: [gate.entered], timeout: 1)
        XCTAssertEqual(environment.pointer, environment.originalPoint)
        environment.pointer = CGPoint(x: 5, y: 6)
        gate.release()
        _ = await cleanup.value
        XCTAssertEqual(environment.pointerMoves, [environment.targetPoint, environment.originalPoint])
        XCTAssertEqual(environment.focusRestorations, 0)
    }

    private func assertFailure(_ task: Task<Void, Error>, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await task.value; XCTFail("Operation must fail closed", file: file, line: line) } catch {}
    }
}

private enum PreparedReceiptMutation: Equatable, CaseIterable {
    case generation, purpose, owner, point
}

@MainActor
private final class PreparedDriverEnvironment: NativeScrollCaptureEnvironment {
    let originalPoint = CGPoint(x: 3, y: 4)
    let targetPoint = CGPoint(x: 100, y: 100)
    let identity: ScrollTargetIdentity
    var currentIdentity: ScrollTargetIdentity
    var pointer: CGPoint? = CGPoint(x: 3, y: 4)
    var access = true
    var displayIsCurrent = true
    var resolutionGate: PreparedTestGate?
    var initialMetadataGate: PreparedTestGate?
    var initialInput = ScrollTargetWindowPolicy.InputObservation(windowNumber: 417, foregroundPID: 701)
    var gates: [NativeScrollCapturePurpose: PreparedTestGate] = [:]
    var receiptMutation: PreparedReceiptMutation?
    var metadataElapsed: Duration = .zero
    var metadataRow: [String: Any]
    private var clock = ContinuousClock.now
    private(set) var resolutions = 0
    private(set) var metadataReads = 0
    private(set) var purposes: [NativeScrollCapturePurpose] = []
    private(set) var events: [Int32] = []
    private(set) var pointerMoves: [CGPoint] = []
    private(set) var focusRestorations = 0
    var afterDispatch: ((Int32) -> Void)?

    init() {
        // Handles are opaque values used only by the real CFEqual comparison;
        // they do not establish live AX ownership and are never queried.
        let original = ScrollTargetIdentity(pid: 701, windowID: 417,
            windowFrame: CGRect(x: 10, y: 20, width: 300, height: 200),
            scrollFrame: CGRect(x: 20, y: 40, width: 200, height: 150),
            window: AXUIElementCreateApplication(701), scrollArea: AXUIElementCreateApplication(702))
        identity = original
        currentIdentity = original
        metadataRow = [kCGWindowNumber as String: 417, kCGWindowOwnerPID as String: 701,
            kCGWindowBounds as String: ["X": 10, "Y": 20, "Width": 300, "Height": 200],
            kCGWindowAlpha as String: 1.0, kCGWindowIsOnscreen as String: true,
            kCGWindowLayer as String: 0, kCGWindowSharingState as String: 1,
            kCGWindowStoreType as String: 2, kCGWindowMemoryUsage as String: 1_048_576]
    }

    func resolveTarget(in region: ScrollCaptureRegion) async throws -> NativeScrollCaptureTarget {
        resolutions += 1
        await resolutionGate?.wait()
        let initialMetadata = ScrollTargetMetadataPreparation(now: { self.clock }, read: { _ in
            await self.initialMetadataGate?.wait()
            guard let parsed = ScrollTargetWindowMetadata.parseBound([self.metadataRow],
                windowID: self.currentIdentity.windowID) else { return nil }
            return [parsed]
        })
        let binding = ScrollTargetInitialBindingPreparation(metadata: initialMetadata,
            readInput: { self.initialInput }, resolve: { snapshot in
                let current = self.currentIdentity
                guard ScrollTargetWindowPolicy.resolveStable(point: self.targetPoint, ownerPID: current.pid,
                    axWindowFrame: current.windowFrame, windows: snapshot.windows,
                    readCurrentInput: { self.initialInput }) == current.windowID else { return nil }
                return current
            })
        guard let bound = await binding.prepare() else { throw CaptureError.failed("Initial recipient changed") }
        let targetID = UUID()
        return NativeScrollCaptureTarget(id: targetID, point: targetPoint, ownerPID: bound.pid) { purpose in
            self.purposes.append(purpose)
            let preparation = ScrollTargetMetadataPreparation(now: { self.clock }, read: { requestedID in
                self.metadataReads += 1
                await self.gates[purpose]?.wait()
                self.clock = self.clock.advanced(by: self.metadataElapsed)
                guard let requestedID,
                      let window = ScrollTargetWindowMetadata.parseBound([self.metadataRow], windowID: requestedID) else { return nil }
                return [window]
            })
            guard let snapshot = await preparation.prepare(boundTo: bound), let row = snapshot.windows.first else { return nil }
            return NativeScrollCaptureReceipt(targetID: self.receiptMutation == .generation ? UUID() : targetID,
                point: self.receiptMutation == .point ? CGPoint(x: 101, y: 100) : self.targetPoint,
                ownerPID: self.receiptMutation == .owner ? 702 : bound.pid,
                purpose: self.receiptMutation == .purpose ? .validation : purpose,
                deadline: snapshot.deadline, now: { self.clock }, isCurrent: {
                    self.displayIsCurrent && bound.matches(self.currentIdentity) &&
                    ScrollTargetWindowPolicy.resolveBoundStable(point: self.targetPoint, ownerPID: bound.pid,
                        axWindowFrame: bound.windowFrame, windowID: bound.windowID, window: row,
                        readCurrentInput: { self.initialInput }) == bound.windowID
                })
        }
    }

    func hasAccess() -> Bool { access }
    func pointerLocation() -> CGPoint? { pointer }
    func movePointer(to point: CGPoint) -> Bool { pointerMoves.append(point); pointer = point; return true }
    func focusRestoration() -> @MainActor () -> Void { { self.focusRestorations += 1 } }
    func postWheel(_ delta: Int32, using receipt: NativeScrollCaptureReceipt, restoring: Bool) -> Bool {
        NativeScrollWheelDelivery(hasAccess: { self.access }, pointerLocation: { self.pointer },
            isCancelled: { Task.isCancelled }, dispatch: { event in
                let delivered = Int32(NSEvent(cgEvent: event)!.scrollingDeltaY)
                self.events.append(delivered)
                self.afterDispatch?(delivered)
            }).post(delta, using: receipt, restoring: restoring)
    }
}

@MainActor
final class PreparedTestGate {
    let entered: XCTestExpectation
    private var released = false
    private var announced = false
    private var continuations: [CheckedContinuation<Void, Never>] = []
    init(_ name: String) { entered = XCTestExpectation(description: name) }
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
            if !announced { announced = true; entered.fulfill() }
        }
    }
    func release() {
        released = true
        let waiting = continuations
        continuations.removeAll()
        for continuation in waiting { continuation.resume() }
    }
}

func preparedTestRegion() -> ScrollCaptureRegion {
    ScrollCaptureRegion(displayID: 1, displayFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
        rect: CGRect(x: 50, y: 50, width: 100, height: 100))
}
