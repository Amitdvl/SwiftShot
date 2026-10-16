import XCTest
@testable import SwiftShot

@MainActor
final class CaptureRequestDeadlineTests: XCTestCase {
    // Break: substituting a default result instead of forwarding successful acquisition.
    func testCompletedRequestReturnsItsExactValue() async throws {
        let request = Task<Int, Error> { 47 }
        let result = try await CaptureRequestDeadline.value(of: request, timeout: .seconds(1))
        XCTAssertEqual(result, 47)
    }

    // Break: wrapping an SDK error loses the original error and recovery information.
    func testRequestErrorPreservesItsIdentity() async {
        let expected = NSError(domain: "SyntheticCaptureSDK", code: 731)
        let request = Task<Int, Error> { throw expected }
        do {
            _ = try await CaptureRequestDeadline.value(of: request, timeout: .seconds(1))
            XCTFail("A failed native request must fail its waiter")
        } catch {
            XCTAssertTrue((error as NSError) === expected)
        }
    }

    // Break: structured timeout waits for an SDK task that ignores cancellation,
    // or returns early by releasing that task's still-live capture reservation.
    func testTimeoutReturnsWithoutDrainingNativeRequestOrReleasingItsReservation() async throws {
        let started = expectation(description: "Native request owns the reservation")
        let completed = expectation(description: "Deadline returned while native request remains suspended")
        let gate = DeadlineNativeGate()
        let budget = CaptureMemoryBudget(limit: 32)
        let request = Task<Int, Error> {
            try budget.reserve(32)
            defer { budget.release(32) }
            started.fulfill()
            await gate.wait()
            return 91
        }
        let result = DeadlineResult()
        let waiter = Task {
            do { result.value = .success(try await CaptureRequestDeadline.value(of: request, timeout: .milliseconds(25))) }
            catch { result.value = .failure(error) }
            completed.fulfill()
        }
        defer { waiter.cancel(); request.cancel(); gate.release() }
        await fulfillment(of: [started, completed], timeout: 2)
        guard case .failure(let error) = result.value else {
            gate.release()
            return XCTFail("A non-completing native request must produce a bounded capture failure")
        }
        guard let captureError = error as? CaptureError, case .failed(let message) = captureError else {
            gate.release()
            return XCTFail("Timeout must report a recoverable capture error, got \(error)")
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertTrue(request.isCancelled, "Timeout must request cancellation of native acquisition")
        XCTAssertThrowsError(try budget.reserve(1), "Pending native work must retain its allocation budget")
        gate.release()
        _ = try await request.value
        try budget.reserve(32)
        budget.release(32)
        // A late successful native result must not replace the deadline failure
        // or resume a continuation twice (which would crash the test process).
        await waiter.value
        guard case .failure = result.value else { return XCTFail("Late native success replaced the timeout") }
    }

    // Break: cancellation only cancels the native task, then keeps awaiting it.
    func testCallerCancellationReturnsBeforeUncooperativeNativeRequestCompletes() async throws {
        let started = expectation(description: "Native request started")
        let completed = expectation(description: "Cancelled waiter returned")
        let gate = DeadlineNativeGate()
        let request = Task<Int, Error> { started.fulfill(); await gate.wait(); return 64 }
        let result = DeadlineResult()
        let waiter = Task {
            do { result.value = .success(try await CaptureRequestDeadline.value(of: request, timeout: .seconds(30))) }
            catch { result.value = .failure(error) }
            completed.fulfill()
        }
        defer { waiter.cancel(); request.cancel(); gate.release() }
        await fulfillment(of: [started], timeout: 1)
        waiter.cancel()
        await fulfillment(of: [completed], timeout: 1)
        XCTAssertTrue(request.isCancelled)
        guard case .failure(let error) = result.value else {
            gate.release()
            return XCTFail("Cancellation must finish without native completion")
        }
        XCTAssertTrue(error is CancellationError)
        gate.release()
        _ = try await request.value
        await waiter.value
        guard case .failure(let lateError) = result.value else { return XCTFail("Late completion replaced cancellation") }
        XCTAssertTrue(lateError is CancellationError)
    }

    // Break: cancellation before the waiter installs its continuation is lost.
    func testAlreadyCancelledWaiterDoesNotWaitForNativeCompletion() async {
        let completed = expectation(description: "Pre-cancelled waiter returned")
        let gate = DeadlineNativeGate()
        let request = Task<Int, Error> { await gate.wait(); return 12 }
        let result = DeadlineResult()
        let waiter = Task {
            do { result.value = .success(try await CaptureRequestDeadline.value(of: request, timeout: .seconds(30))) }
            catch { result.value = .failure(error) }
            completed.fulfill()
        }
        // No suspension occurs between creation and cancellation, so MainActor
        // cannot start the waiter before the cancellation flag is installed.
        waiter.cancel()
        defer { gate.release(); request.cancel() }
        await fulfillment(of: [completed], timeout: 1)
        XCTAssertTrue(request.isCancelled)
        guard case .failure(let error) = result.value else {
            return XCTFail("A pre-cancelled waiter must return without the SDK callback")
        }
        XCTAssertTrue(error is CancellationError)
        gate.release()
        _ = try? await request.value
        await waiter.value
    }

}

@MainActor
private final class DeadlineResult {
    var value: Result<Int, any Error>?
}

/// Deliberately ignores cancellation, matching an SDK callback which never arrives.
/// Tests always release it after their bounded expectation, including the RED path.
@MainActor
private final class DeadlineNativeGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
