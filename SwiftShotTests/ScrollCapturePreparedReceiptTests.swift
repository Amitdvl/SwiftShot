import AppKit
import ApplicationServices
import XCTest
@testable import SwiftShot

/// Metadata admission and receipt consumption are production code. Only the
/// external metadata request, clock, accessibility result, and event sink are
/// supplied here. These tests never query windows, capture pixels, or post input.
@MainActor
final class ScrollCapturePreparedReceiptTests: XCTestCase {
    private typealias Window = ScrollTargetWindowPolicy.Window
    private let point = CGPoint(x: 50, y: 60)

    // Break: preparation rebinds a different ID or resets its deadline on return.
    func testFreshBoundMetadataPreservesOriginalIDAndOriginalDeadline() async throws {
        let clock = ReceiptClock()
        let expected = identity()
        let parsed = try parsedRow()
        let preparation = ScrollTargetMetadataPreparation(now: { clock.instant }, read: { requestedID in
            guard requestedID == 417 else { return nil }
            clock.advance(.milliseconds(40))
            return [parsed]
        })
        let prepared = await preparation.prepare(boundTo: expected)
        let snapshot = try XCTUnwrap(prepared)
        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertEqual(snapshot.windows.first?.id, 417)
        XCTAssertEqual(snapshot.windows.first?.ownerPID, 701)
        XCTAssertEqual(snapshot.deadline, clock.origin.advanced(by: .milliseconds(200)))
    }

    // Break: malformed public metadata receives defaults before preparation.
    func testMalformedMetadataNeverProducesPreparation() async {
        for key in [kCGWindowNumber, kCGWindowOwnerPID, kCGWindowBounds, kCGWindowAlpha, kCGWindowIsOnscreen] {
            var value = row()
            value.removeValue(forKey: key as String)
            let clock = ReceiptClock()
            let preparation = ScrollTargetMetadataPreparation(now: { clock.instant }, read: { requestedID in
                guard let requestedID,
                      let parsed = ScrollTargetWindowMetadata.parseBound([value], windowID: requestedID) else { return nil }
                return [parsed]
            })
            let snapshot = await preparation.prepare(boundTo: identity())
            XCTAssertNil(snapshot, "Missing \(key) must not authorize later AX validation")
        }
    }

    // Break: a validly parsed reused window ID under another process is admitted.
    func testForeignOwnerMetadataCannotPrepareOriginalIdentity() async throws {
        var value = row()
        value[kCGWindowOwnerPID as String] = 702
        let foreign = try XCTUnwrap(ScrollTargetWindowMetadata.parseBound([value], windowID: 417))
        let clock = ReceiptClock()
        let preparation = ScrollTargetMetadataPreparation(now: { clock.instant }, read: { _ in [foreign] })
        let snapshot = await preparation.prepare(boundTo: identity())
        XCTAssertNil(snapshot)
    }

    // Break: preparer trusts injected/native rows without preserving all binding fields.
    func testChangedOrHiddenBoundMetadataCannotPrepareOriginalIdentity() async {
        var hidden = window()
        hidden.isOnScreen = false
        let badRows = [window(id: 418), window(owner: 702),
                       window(frame: CGRect(x: 11, y: 20, width: 300, height: 200)),
                       window(frame: CGRect(x: 10, y: 20, width: 301, height: 200)),
                       window(alpha: 0), window(alpha: .nan), hidden]
        for bad in badRows {
            let clock = ReceiptClock()
            let preparation = ScrollTargetMetadataPreparation(now: { clock.instant }, read: { _ in [bad] })
            let snapshot = await preparation.prepare(boundTo: identity())
            XCTAssertNil(snapshot)
        }
    }

    // Break: a broad, duplicated, or empty response is silently reduced to one row.
    func testBoundPreparationRejectsMissingDuplicateAndExtraRows() async {
        let responses: [[Window]] = [[], [window(), window()], [window(), window(id: 418)]]
        for response in responses {
            let clock = ReceiptClock()
            let preparation = ScrollTargetMetadataPreparation(now: { clock.instant }, read: { _ in response })
            let snapshot = await preparation.prepare(boundTo: identity())
            XCTAssertNil(snapshot)
        }
    }

    // Break: unavailable metadata triggers a retry that can hide a first failure.
    func testUnavailableMetadataIsTerminalWithoutRetry() async {
        let clock = ReceiptClock()
        var requests = 0
        let preparation = ScrollTargetMetadataPreparation(now: { clock.instant }, read: { _ in
            requests += 1
            return requests == 1 ? nil : [self.window()]
        })
        let snapshot = await preparation.prepare(boundTo: identity())
        XCTAssertNil(snapshot)
        XCTAssertEqual(requests, 1, "A later valid response must not repair unavailable evidence")
    }

    // Break: only native execution time counts; queue wait/resumption gets a new budget.
    func testSuspendedPreparationCountsTheWholeAwaitAgainstFreshness() async {
        let clock = ReceiptClock()
        let gate = ReceiptGate()
        let expected = identity()
        let valid = window()
        let preparation = ScrollTargetMetadataPreparation(now: { clock.instant }, read: { _ in
            await gate.wait()
            return [valid]
        })
        let work = Task { @MainActor in await preparation.prepare(boundTo: expected) }
        await fulfillment(of: [gate.entered], timeout: 1)
        clock.advance(.milliseconds(201))
        gate.release()
        let snapshot = await work.value
        XCTAssertNil(snapshot, "Late metadata is discarded even though the row itself is valid")
    }

    // Break: a 200 ms boundary is made inclusive or a late result is refreshed.
    func testMetadataAtTheDeadlineIsRejectedAndNotRetried() async {
        let clock = ReceiptClock()
        var requests = 0
        let preparation = ScrollTargetMetadataPreparation(now: { clock.instant }, read: { _ in
            requests += 1
            clock.advance(.milliseconds(200))
            return [self.window()]
        })
        let snapshot = await preparation.prepare(boundTo: identity())
        XCTAssertNil(snapshot)
        XCTAssertEqual(requests, 1)
    }

    // Break: a preparer always rejects instead of allowing genuinely fresh data.
    func testMetadataJustInsideTheDeadlineRemainsAdmissible() async {
        let clock = ReceiptClock()
        let preparation = ScrollTargetMetadataPreparation(now: { clock.instant }, read: { _ in
            clock.advance(.milliseconds(199))
            return [self.window()]
        })
        let snapshot = await preparation.prepare(boundTo: identity())
        XCTAssertNotNil(snapshot)
    }

    // Break: initial preparation preselects one row and loses ambiguity evidence.
    func testInitialPreparationKeepsAllRowsForRealAmbiguityPolicy() async throws {
        let clock = ReceiptClock()
        let preparation = ScrollTargetMetadataPreparation(now: { clock.instant }, read: { requestedID in
            guard requestedID == nil else { return nil }
            return [self.window(), self.window(id: 418)]
        })
        let prepared = await preparation.prepare(boundTo: nil)
        let snapshot = try XCTUnwrap(prepared)
        XCTAssertEqual(snapshot.windows.count, 2)
        XCTAssertNil(ScrollTargetWindowPolicy.resolveStable(point: point, ownerPID: 701,
            axWindowFrame: CGRect(x: 10, y: 20, width: 300, height: 200), windows: snapshot.windows,
            readCurrentInput: { .init(windowNumber: 417, foregroundPID: 701) }))
    }

    // Break: a receipt is reusable, allowing a second effect without preparation.
    func testFreshReceiptCanBeConsumedExactlyOnceIncludingThroughAnAlias() {
        let clock = ReceiptClock()
        var checks = 0
        let receipt = receipt(clock: clock) { checks += 1; return true }
        let alias = receipt
        XCTAssertTrue(receipt.consume())
        XCTAssertFalse(alias.consume())
        XCTAssertEqual(checks, 1)
    }

    // Break: a failed synchronous identity check can be repaired by reusing a receipt.
    func testRejectedReceiptRemainsConsumedAfterIdentityBecomesValid() {
        let clock = ReceiptClock()
        var current = false
        let receipt = receipt(clock: clock) { current }
        XCTAssertFalse(receipt.consume())
        current = true
        XCTAssertFalse(receipt.consume())
    }

    // Break: metadata is checked only at preparation, not before final AX work.
    func testReceiptExpiredBeforeConsumptionDoesNotReadIdentity() {
        let clock = ReceiptClock()
        var checks = 0
        let receipt = receipt(clock: clock) { checks += 1; return true }
        clock.advance(.milliseconds(200))
        XCTAssertFalse(receipt.consume())
        XCTAssertEqual(checks, 0)
    }

    // Break: a slow final AX/native check is accepted after the shared deadline.
    func testReceiptExpiresDuringFinalIdentityCheck() {
        let clock = ReceiptClock()
        let receipt = receipt(clock: clock) { clock.advance(.milliseconds(201)); return true }
        XCTAssertFalse(receipt.consume())
    }

    // Break: a failed permission/pointer/generation precondition can reuse its receipt.
    func testFailedContextCheckConsumesReceiptWithoutReadingIdentity() {
        let clock = ReceiptClock()
        var checks = 0
        let receipt = receipt(clock: clock) { checks += 1; return true }
        XCTAssertFalse(receipt.consume(while: { false }))
        XCTAssertFalse(receipt.consume(while: { true }))
        XCTAssertEqual(checks, 0)
    }

    // Break: context is only checked before a reentrant final identity lookup.
    func testContextChangeDuringIdentityCheckRejectsReceipt() {
        let clock = ReceiptClock()
        var current = true
        let receipt = receipt(clock: clock) { current = false; return true }
        XCTAssertFalse(receipt.consume(while: { current }))
    }

    // Break: the final context check consumes the remaining budget but still authorizes an effect.
    func testReceiptExpiresDuringFinalContextCheck() {
        let clock = ReceiptClock()
        var checks = 0
        let receipt = receipt(clock: clock)
        XCTAssertFalse(receipt.consume(while: {
            checks += 1
            if checks == 2 { clock.advance(.milliseconds(200)) }
            return true
        }))
    }

    // Break: receipt metadata is decoupled from the exact final native-window policy.
    func testPreparedRowAndRealNativePolicyRejectSameProcessReplacement() async throws {
        let clock = ReceiptClock()
        let expected = identity()
        let parsed = try parsedRow()
        let preparation = ScrollTargetMetadataPreparation(now: { clock.instant }, read: { _ in [parsed] })
        let prepared = await preparation.prepare(boundTo: expected)
        let snapshot = try XCTUnwrap(prepared)
        let metadata = try XCTUnwrap(snapshot.windows.first)
        var nativeWindow = 417
        let receipt = NativeScrollCaptureReceipt(point: point, ownerPID: 701, purpose: .forwardScroll,
            deadline: snapshot.deadline, now: { clock.instant }, isCurrent: {
                ScrollTargetWindowPolicy.resolveBoundStable(point: self.point,
                    ownerPID: expected.pid, axWindowFrame: expected.windowFrame, windowID: expected.windowID,
                    window: metadata, readCurrentInput: { .init(windowNumber: nativeWindow, foregroundPID: 701) }) == 417
            })
        nativeWindow = 418
        var events: [CGEvent] = []
        let delivery = poster(dispatch: { events.append($0) })
        XCTAssertFalse(delivery.post(-80, using: receipt, restoring: false))
        XCTAssertTrue(events.isEmpty)
    }

    // Break: the prepared path constructs no event or loses precise delta/target coordinates.
    func testPreparedForwardDeliveryUsesRealEventConstructorAndFinalBoundary() throws {
        let clock = ReceiptClock()
        var events: [CGEvent] = []
        let delivery = poster(dispatch: { events.append($0) })
        XCTAssertTrue(delivery.post(-80, using: receipt(clock: clock), restoring: false))
        XCTAssertEqual(events.count, 1)
        let native = try XCTUnwrap(events.first.flatMap { NSEvent(cgEvent: $0) })
        XCTAssertTrue(native.hasPreciseScrollingDeltas)
        XCTAssertEqual(native.scrollingDeltaY, -80)
        XCTAssertEqual(events.first?.location, point)
    }

    // Break: a successfully dispatched receipt authorizes another wheel.
    func testPreparedReceiptCannotDispatchTwoEvents() {
        let clock = ReceiptClock()
        let receipt = receipt(clock: clock)
        var events: [CGEvent] = []
        let delivery = poster(dispatch: { events.append($0) })
        XCTAssertTrue(delivery.post(-80, using: receipt, restoring: false))
        XCTAssertFalse(delivery.post(-80, using: receipt, restoring: false))
        XCTAssertEqual(events.count, 1)
    }

    // Break: posting-permission rejection does not invalidate a prepared authority.
    func testPreparedPermissionFailureCannotBeRetriedWithSameReceipt() {
        let clock = ReceiptClock()
        let receipt = receipt(clock: clock)
        var events: [CGEvent] = []
        var delivery = poster(dispatch: { events.append($0) })
        delivery.hasAccess = { false }
        XCTAssertFalse(delivery.post(-80, using: receipt, restoring: false))
        delivery.hasAccess = { true }
        XCTAssertFalse(delivery.post(-80, using: receipt, restoring: false))
        XCTAssertTrue(events.isEmpty)
    }

    // Break: final cancellation after AX validation is ignored by the prepared path.
    func testPreparedCancellationDuringIdentityCheckPreventsDispatch() {
        let clock = ReceiptClock()
        var cancelled = false
        let receipt = receipt(clock: clock) { cancelled = true; return true }
        var events: [CGEvent] = []
        var delivery = poster(dispatch: { events.append($0) })
        delivery.isCancelled = { cancelled }
        XCTAssertFalse(delivery.post(-80, using: receipt, restoring: false))
        XCTAssertTrue(events.isEmpty)
    }

    // Break: cancellation during the final pointer read is checked only before that read.
    func testPreparedCancellationDuringFinalPointerReadPreventsDispatch() {
        let clock = ReceiptClock()
        var cancelled = false
        var pointerReads = 0
        var events: [CGEvent] = []
        var delivery = poster(dispatch: { events.append($0) })
        delivery.isCancelled = { cancelled }
        delivery.pointerLocation = {
            pointerReads += 1
            if pointerReads == 2 { cancelled = true }
            return self.point
        }
        XCTAssertFalse(delivery.post(-80, using: receipt(clock: clock), restoring: false))
        XCTAssertEqual(pointerReads, 2)
        XCTAssertTrue(events.isEmpty)
    }

    // Break: a pointer change during the final AX/native lookup still posts input.
    func testPreparedPointerChangeDuringIdentityCheckPreventsDispatch() {
        let clock = ReceiptClock()
        var pointer: CGPoint? = point
        let receipt = receipt(clock: clock) { pointer = CGPoint(x: 51, y: 60); return true }
        var events: [CGEvent] = []
        var delivery = poster(dispatch: { events.append($0) })
        delivery.pointerLocation = { pointer }
        XCTAssertFalse(delivery.post(-80, using: receipt, restoring: false))
        XCTAssertTrue(events.isEmpty)
    }

    // Break: a restoration receipt can be repurposed for forward input (or vice versa).
    func testPreparedPurposeMustMatchEffectDirection() {
        let clock = ReceiptClock()
        var events: [CGEvent] = []
        let delivery = poster(dispatch: { events.append($0) })
        XCTAssertFalse(delivery.post(-80, using: receipt(clock: clock, purpose: .pageRestoration), restoring: false))
        XCTAssertFalse(delivery.post(80, using: receipt(clock: clock), restoring: true))
        XCTAssertFalse(delivery.post(-80, using: receipt(clock: clock, purpose: .validation), restoring: false))
        XCTAssertTrue(events.isEmpty)
    }

    // Break: a wrong-purpose attempt leaves its receipt available for a later effect.
    func testWrongPurposeAttemptConsumesReceiptBeforeAnyLaterValidUse() {
        let clock = ReceiptClock()
        let receipt = receipt(clock: clock, purpose: .pageRestoration)
        var events: [CGEvent] = []
        let delivery = poster(dispatch: { events.append($0) })
        XCTAssertFalse(delivery.post(-80, using: receipt, restoring: false))
        XCTAssertFalse(delivery.post(80, using: receipt, restoring: true))
        XCTAssertTrue(events.isEmpty)
    }

    // Break: an invalid wheel direction does not consume its prepared authority.
    func testWrongDirectionAttemptConsumesReceiptBeforeAnyLaterValidUse() {
        let clock = ReceiptClock()
        let receipt = receipt(clock: clock)
        var events: [CGEvent] = []
        let delivery = poster(dispatch: { events.append($0) })
        XCTAssertFalse(delivery.post(80, using: receipt, restoring: false))
        XCTAssertFalse(delivery.post(-80, using: receipt, restoring: false))
        XCTAssertTrue(events.isEmpty)
    }

    // Break: universal cancellation rejection prevents explicitly authorized positive cleanup.
    func testCancelledPreparedCleanupAllowsOnlyPositivePageRestoration() {
        let clock = ReceiptClock()
        var deltas: [CGFloat] = []
        var delivery = poster(dispatch: { deltas.append(NSEvent(cgEvent: $0)!.scrollingDeltaY) })
        delivery.isCancelled = { true }
        XCTAssertFalse(delivery.post(-80, using: receipt(clock: clock), restoring: false))
        XCTAssertFalse(delivery.post(-80, using: receipt(clock: clock, purpose: .pageRestoration), restoring: true))
        XCTAssertTrue(delivery.post(80, using: receipt(clock: clock, purpose: .pageRestoration), restoring: true))
        XCTAssertEqual(deltas, [80])
    }

    private func receipt(clock: ReceiptClock, purpose: NativeScrollCapturePurpose = .forwardScroll,
                         isCurrent: @escaping @MainActor () -> Bool = { true }) -> NativeScrollCaptureReceipt {
        NativeScrollCaptureReceipt(point: point, ownerPID: 701, purpose: purpose,
            deadline: clock.origin.advanced(by: .milliseconds(200)), now: { clock.instant }, isCurrent: isCurrent)
    }

    private func poster(dispatch: @escaping (CGEvent) -> Void) -> NativeScrollWheelDelivery {
        NativeScrollWheelDelivery(hasAccess: { true }, pointerLocation: { self.point },
            isCancelled: { false }, dispatch: dispatch)
    }

    private func row() -> [String: Any] {
        [kCGWindowNumber as String: 417, kCGWindowOwnerPID as String: 701,
         kCGWindowBounds as String: ["X": 10, "Y": 20, "Width": 300, "Height": 200],
         kCGWindowAlpha as String: 1.0, kCGWindowIsOnscreen as String: true,
         kCGWindowLayer as String: 0, kCGWindowSharingState as String: 1,
         kCGWindowStoreType as String: 2, kCGWindowMemoryUsage as String: 1_048_576]
    }

    private func parsedRow() throws -> Window {
        try XCTUnwrap(ScrollTargetWindowMetadata.parseBound([row()], windowID: 417))
    }

    private func window(id: CGWindowID = 417, owner: pid_t = 701,
                        frame: CGRect = CGRect(x: 10, y: 20, width: 300, height: 200), alpha: Double = 1) -> Window {
        Window(id: id, ownerPID: owner, frame: frame, alpha: alpha)
    }

    private func identity() -> ScrollTargetIdentity {
        // Opaque handle comparison only: no AX calls or real application ownership.
        ScrollTargetIdentity(pid: 701, windowID: 417, windowFrame: CGRect(x: 10, y: 20, width: 300, height: 200),
            scrollFrame: CGRect(x: 20, y: 40, width: 200, height: 150),
            window: AXUIElementCreateApplication(701), scrollArea: AXUIElementCreateApplication(702))
    }
}

@MainActor
private final class ReceiptClock {
    let origin = ContinuousClock.now
    private(set) var offset: Duration = .zero
    var instant: ContinuousClock.Instant { origin.advanced(by: offset) }
    func advance(_ duration: Duration) { offset += duration }
}

@MainActor
private final class ReceiptGate {
    let entered = XCTestExpectation(description: "Metadata request is suspended")
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered.fulfill()
        }
    }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}
