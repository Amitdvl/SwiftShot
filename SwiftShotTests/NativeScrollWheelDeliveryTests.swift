import AppKit
import XCTest
@testable import SwiftShot

/// Uses the production event constructor and final guard boundary, but captures
/// events in-process. These tests never synthesize system input or claim delivery.
@MainActor
final class NativeScrollWheelDeliveryTests: XCTestCase {
    private let point = CGPoint(x: 100, y: 100)

    func testValidForwardEventPreservesPointAndPreciseDelta() throws {
        var events: [CGEvent] = []
        let delivery = poster(dispatch: { events.append($0) })
        XCTAssertTrue(delivery.post(-80, using: target(), restoring: false))
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(event.type, .scrollWheel)
        XCTAssertEqual(event.location, point)
        let native = try XCTUnwrap(NSEvent(cgEvent: event))
        XCTAssertTrue(native.hasPreciseScrollingDeltas)
        XCTAssertEqual(native.scrollingDeltaY, -80)
    }

    func testMissingPostingPermissionRefusesEvent() {
        var sent = false
        var delivery = poster(dispatch: { _ in sent = true })
        delivery.hasAccess = { false }
        XCTAssertFalse(delivery.post(-80, using: target(), restoring: false))
        XCTAssertFalse(sent)
    }

    func testForeignPointerBeforeIdentityRefusesEvent() {
        var sent = false
        var delivery = poster(dispatch: { _ in sent = true })
        delivery.pointerLocation = { CGPoint(x: 500, y: 500) }
        XCTAssertFalse(delivery.post(-80, using: target(), restoring: false))
        XCTAssertFalse(sent)
    }

    func testPointerMovedDuringIdentityCheckRefusesEvent() {
        var sent = false
        var pointer: CGPoint? = point
        var delivery = poster(dispatch: { _ in sent = true })
        delivery.pointerLocation = { pointer }
        let identity = target { pointer = nil; return true }
        XCTAssertFalse(delivery.post(-80, using: identity, restoring: false))
        XCTAssertFalse(sent)
    }

    func testFinalIdentityRejectionRefusesForwardAndRestoration() {
        var sent = false
        let delivery = poster(dispatch: { _ in sent = true })
        XCTAssertFalse(delivery.post(-80, using: target { false }, restoring: false))
        XCTAssertFalse(delivery.post(80, using: target(restoring: true) { false }, restoring: true))
        XCTAssertFalse(sent)
    }

    func testCancellationDuringIdentityCheckRefusesForwardEvent() {
        var sent = false
        var cancelled = false
        var delivery = poster(dispatch: { _ in sent = true })
        delivery.isCancelled = { cancelled }
        XCTAssertFalse(delivery.post(-80, using: target { cancelled = true; return true }, restoring: false))
        XCTAssertFalse(sent)
    }

    func testCancelledCleanupAllowsOnlyExplicitPositiveRestoration() {
        var deltas: [CGFloat] = []
        var delivery = poster(dispatch: { event in deltas.append(NSEvent(cgEvent: event)!.scrollingDeltaY) })
        delivery.isCancelled = { true }
        XCTAssertFalse(delivery.post(-80, using: target(), restoring: false))
        XCTAssertFalse(delivery.post(-80, using: target(restoring: true), restoring: true))
        XCTAssertFalse(delivery.post(80, using: target(), restoring: false))
        XCTAssertFalse(delivery.post(0, using: target(restoring: true), restoring: true))
        XCTAssertTrue(delivery.post(80, using: target(restoring: true), restoring: true))
        XCTAssertEqual(deltas, [80])
    }

    func testCancellationNeverBypassesRestorationPointerGuard() {
        var sent = false
        var delivery = poster(dispatch: { _ in sent = true })
        delivery.isCancelled = { true }
        delivery.pointerLocation = { nil }
        XCTAssertFalse(delivery.post(80, using: target(restoring: true), restoring: true))
        XCTAssertFalse(sent)
    }

    func testObservedPointerExcursionLatchesLossEvenAfterReturn() async throws {
        let environment = WheelDriverEnvironment()
        let driver = NativeScrollCaptureDriver(environment: environment)
        try await driver.begin(in: region())
        try await driver.scrollDown(points: 80)
        driver.recordObservedMovement(points: 80)
        environment.pointer = CGPoint(x: 101, y: 100)
        do { try await driver.validateTarget(); XCTFail("Target validation must reject") } catch {}
        environment.pointer = point
        do { try await driver.validateTarget(); XCTFail("Target validation must reject") } catch {}
        let warning = await driver.restore()
        XCTAssertTrue(warning?.contains("pointer moved") == true)
        XCTAssertEqual(environment.events, [-80])
        XCTAssertEqual(environment.pointerMoves, [point])
        XCTAssertEqual(environment.focusRestorations, 0)
    }

    func testFinalDispatchRefusalLatchesLossAndLeavesUserContextAlone() async throws {
        let environment = WheelDriverEnvironment()
        let driver = NativeScrollCaptureDriver(environment: environment)
        try await driver.begin(in: region())
        environment.deliveryAllowed = false
        do { try await driver.scrollDown(points: 80); XCTFail("Dispatch rejection must stop Auto") } catch {}
        environment.deliveryAllowed = true
        do { try await driver.validateTarget(); XCTFail("Target validation must reject") } catch {}
        _ = await driver.restore()
        XCTAssertTrue(environment.events.isEmpty)
        XCTAssertEqual(environment.pointerMoves, [point])
        XCTAssertEqual(environment.focusRestorations, 0)
    }

    func testUnchangedTargetRestoresObservedPagePointerAndFocus() async throws {
        let environment = WheelDriverEnvironment()
        let driver = NativeScrollCaptureDriver(environment: environment)
        try await driver.begin(in: region())
        try await driver.scrollDown(points: 80)
        driver.recordObservedMovement(points: 80)
        let warning = await driver.restore()
        XCTAssertEqual(environment.events, [-80, 80])
        XCTAssertEqual(environment.restorationFlags, [false, true])
        XCTAssertEqual(environment.pointerMoves, [point, CGPoint(x: 3, y: 4)])
        XCTAssertEqual(environment.focusRestorations, 1)
        XCTAssertTrue(warning?.contains("cannot be verified") == true)
    }

    func testPointerChangedDuringReverseDispatchSuppressesRemainingCleanup() async throws {
        let environment = WheelDriverEnvironment()
        let driver = NativeScrollCaptureDriver(environment: environment)
        try await driver.begin(in: region())
        try await driver.scrollDown(points: 80)
        driver.recordObservedMovement(points: 80)
        environment.afterPost = { restoring in
            if restoring { environment.pointer = CGPoint(x: 700, y: 700) }
        }
        _ = await driver.restore()
        XCTAssertEqual(environment.events, [-80, 80])
        XCTAssertEqual(environment.pointerMoves, [point])
        XCTAssertEqual(environment.focusRestorations, 0)
    }

    func testTargetChangedDuringReverseDispatchSuppressesRemainingCleanup() async throws {
        let environment = WheelDriverEnvironment()
        let driver = NativeScrollCaptureDriver(environment: environment)
        try await driver.begin(in: region())
        try await driver.scrollDown(points: 80)
        driver.recordObservedMovement(points: 80)
        environment.afterPost = { restoring in
            if restoring { environment.targetIsCurrent = false }
        }
        _ = await driver.restore()
        XCTAssertEqual(environment.events, [-80, 80])
        XCTAssertEqual(environment.pointerMoves, [point])
        XCTAssertEqual(environment.focusRestorations, 0)
    }

    func testReverseDispatchRefusalSuppressesRemainingCleanup() async throws {
        let environment = WheelDriverEnvironment()
        let driver = NativeScrollCaptureDriver(environment: environment)
        try await driver.begin(in: region())
        try await driver.scrollDown(points: 80)
        driver.recordObservedMovement(points: 80)
        environment.deliveryAllowed = false
        _ = await driver.restore()
        XCTAssertEqual(environment.events, [-80])
        XCTAssertEqual(environment.pointerMoves, [point])
        XCTAssertEqual(environment.focusRestorations, 0)
    }

    func testPointerRestorationFailureSuppressesFocusRestoration() async throws {
        let environment = WheelDriverEnvironment()
        let driver = NativeScrollCaptureDriver(environment: environment)
        try await driver.begin(in: region())
        environment.pointerRestorationSucceeds = false
        _ = await driver.restore()
        XCTAssertEqual(environment.focusRestorations, 0)
        XCTAssertEqual(environment.pointer, point)
    }

    func testActualCancellationDuringDriverValidationPreventsDispatch() async throws {
        let environment = WheelDriverEnvironment()
        let driver = NativeScrollCaptureDriver(environment: environment)
        try await driver.begin(in: region())
        var operation: Task<Void, Error>!
        environment.onCurrent = { operation.cancel() }
        operation = Task { @MainActor in try await driver.scrollDown(points: 80) }
        do { try await operation.value; XCTFail("Cancellation after validation must prevent dispatch") }
        catch { XCTAssertTrue(error is CancellationError) }
        environment.onCurrent = nil
        _ = await driver.restore()
        XCTAssertTrue(environment.events.isEmpty)
    }

    func testReportedSuccessfulWarpWithWrongPositionSuppressesFocus() async throws {
        let environment = WheelDriverEnvironment()
        let driver = NativeScrollCaptureDriver(environment: environment)
        try await driver.begin(in: region())
        environment.afterMove = { _ in environment.pointer = CGPoint(x: 600, y: 600) }
        _ = await driver.restore()
        XCTAssertEqual(environment.focusRestorations, 0)
        XCTAssertEqual(environment.pointer, CGPoint(x: 600, y: 600))
    }

    func testTargetChangedDuringSuccessfulWarpSuppressesFocus() async throws {
        let environment = WheelDriverEnvironment()
        let driver = NativeScrollCaptureDriver(environment: environment)
        try await driver.begin(in: region())
        environment.afterMove = { _ in environment.targetIsCurrent = false }
        _ = await driver.restore()
        XCTAssertEqual(environment.focusRestorations, 0)
        XCTAssertEqual(environment.pointer, CGPoint(x: 3, y: 4))
    }

    func testPointerChangedDuringFinalCleanupIdentityCheckSuppressesFocus() async throws {
        let environment = WheelDriverEnvironment()
        let driver = NativeScrollCaptureDriver(environment: environment)
        try await driver.begin(in: region())
        environment.onCurrent = {
            if environment.pointer == CGPoint(x: 3, y: 4) { environment.pointer = CGPoint(x: 800, y: 800) }
        }
        _ = await driver.restore()
        XCTAssertEqual(environment.focusRestorations, 0)
        XCTAssertEqual(environment.pointer, CGPoint(x: 800, y: 800))
    }

    private func target(restoring: Bool = false, _ current: @escaping @MainActor () -> Bool = { true }) -> NativeScrollCaptureReceipt {
        NativeScrollCaptureReceipt(point: point, ownerPID: 123,
            purpose: restoring ? .pageRestoration : .forwardScroll,
            deadline: ContinuousClock.now.advanced(by: .milliseconds(200)),
            now: { ContinuousClock.now }, isCurrent: current)
    }
    private func poster(dispatch: @escaping (CGEvent) -> Void) -> NativeScrollWheelDelivery {
        NativeScrollWheelDelivery(hasAccess: { true }, pointerLocation: { self.point },
            isCancelled: { false }, dispatch: dispatch)
    }
    private func region() -> ScrollCaptureRegion {
        ScrollCaptureRegion(displayID: 1, displayFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            rect: CGRect(x: 50, y: 50, width: 100, height: 100))
    }
}

@MainActor
private final class WheelDriverEnvironment: NativeScrollCaptureEnvironment {
    var pointer = CGPoint(x: 3, y: 4)
    var deliveryAllowed = true
    var events: [Int32] = []
    var restorationFlags: [Bool] = []
    var pointerMoves: [CGPoint] = []
    var focusRestorations = 0
    var targetIsCurrent = true
    var onCurrent: (() -> Void)?
    var afterPost: ((Bool) -> Void)?
    var afterMove: ((CGPoint) -> Void)?
    var pointerRestorationSucceeds = true
    func resolveTarget(in region: ScrollCaptureRegion) async throws -> NativeScrollCaptureTarget {
        let id = UUID()
        return NativeScrollCaptureTarget(id: id, point: CGPoint(x: 100, y: 100), ownerPID: 123) { purpose in
            NativeScrollCaptureReceipt(targetID: id, point: CGPoint(x: 100, y: 100), ownerPID: 123,
                purpose: purpose, deadline: ContinuousClock.now.advanced(by: .milliseconds(200)),
                now: { ContinuousClock.now }, isCurrent: {
                    self.onCurrent?()
                    return self.targetIsCurrent
                })
        }
    }
    func hasAccess() -> Bool { true }
    func pointerLocation() -> CGPoint? { pointer }
    func movePointer(to point: CGPoint) -> Bool {
        pointerMoves.append(point)
        guard pointerRestorationSucceeds else { return false }
        pointer = point
        afterMove?(point)
        return true
    }
    func focusRestoration() -> @MainActor () -> Void { { self.focusRestorations += 1 } }
    func postWheel(_ delta: Int32, using receipt: NativeScrollCaptureReceipt, restoring: Bool) -> Bool {
        NativeScrollWheelDelivery(hasAccess: { self.deliveryAllowed }, pointerLocation: { self.pointer },
            isCancelled: { Task.isCancelled }, dispatch: { event in
                self.events.append(Int32(NSEvent(cgEvent: event)!.scrollingDeltaY))
                self.restorationFlags.append(restoring)
                self.afterPost?(restoring)
            }).post(delta, using: receipt, restoring: restoring)
    }
}
