import AppKit
import XCTest
@testable import SwiftShot

/// The real coordinator owns real frame/partial-result state. The native driver
/// boundary supplies noncooperative operations to exercise cancellation ordering.
@MainActor
final class ScrollCaptureCoordinatorAsyncOwnershipTests: XCTestCase {
    // Break: operating is cleared before an awaited cleanup has actually completed.
    func testNormalExitRetainsOperatingUntilAsyncRestorationReturns() async throws {
        let driver = AsyncOwnershipDriver()
        let gate = PreparedTestGate("Normal cleanup")
        driver.restoreGate = gate
        let coordinator = try coordinator(driver: driver, maximumFrames: 1)
        _ = try await coordinator.start()
        let work = Task { @MainActor in try await coordinator.runAutomatic { _, _ in } }
        await fulfillment(of: [gate.entered], timeout: 1)
        await assertStillOperating(coordinator)
        XCTAssertEqual(driver.restoreReturns, 0)
        gate.release()
        try await work.value
        XCTAssertEqual(driver.restorations, 1)
        XCTAssertEqual(driver.restoreReturns, 1)
        let result = try await coordinator.finish()
        XCTAssertEqual(result.image.height, 240)
    }

    // Break: cleanup is registered after begin, so a partially failed begin is never drained.
    func testBeginFailureStillAwaitsCleanupAndPreservesOriginalError() async throws {
        let driver = AsyncOwnershipDriver()
        driver.beginFailure = true
        let gate = PreparedTestGate("Failed-begin cleanup")
        driver.restoreGate = gate
        let coordinator = try coordinator(driver: driver)
        _ = try await coordinator.start()
        let work = Task { @MainActor in try await coordinator.runAutomatic { _, _ in } }
        await fulfillment(of: [gate.entered], timeout: 1)
        await assertStillOperating(coordinator)
        gate.release()
        do { try await work.value; XCTFail("Original begin error must escape") }
        catch { XCTAssertEqual(error as? OwnershipFailure, .begin) }
        XCTAssertEqual(driver.restorations, 1)
        XCTAssertEqual(driver.restoreReturns, 1)
        let result = try await coordinator.finish()
        XCTAssertEqual(result.image.height, 240)
    }

    // Break: cancelling a noncooperative begin releases ownership or skips its later cleanup.
    func testCancelledBeginDrainsNativeWorkAndRestorationBeforeReleasingOwnership() async throws {
        let driver = AsyncOwnershipDriver()
        let beginGate = PreparedTestGate("Noncooperative begin")
        let restoreGate = PreparedTestGate("Cancellation cleanup")
        driver.beginGate = beginGate
        driver.restoreGate = restoreGate
        let coordinator = try coordinator(driver: driver)
        _ = try await coordinator.start()
        let work = Task { @MainActor in try await coordinator.runAutomatic { _, _ in } }
        await fulfillment(of: [beginGate.entered], timeout: 1)
        work.cancel()
        await assertStillOperating(coordinator)
        XCTAssertEqual(driver.restorations, 0)
        beginGate.release()
        await fulfillment(of: [restoreGate.entered], timeout: 1)
        await assertStillOperating(coordinator)
        XCTAssertEqual(driver.restoreReturns, 0)
        restoreGate.release()
        do { try await work.value; XCTFail("Cancelled begin must not continue Auto") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(driver.scrolls, 0)
        XCTAssertEqual(driver.restorations, 1)
        XCTAssertEqual(driver.restoreReturns, 1)
    }

    // Break: cancellation during a noncooperative wheel posts cleanup without awaiting the old operation.
    func testCancelledScrollAwaitsNativeReturnThenCleanupWithoutAcquiringMoreFrames() async throws {
        let driver = AsyncOwnershipDriver()
        let scrollGate = PreparedTestGate("Noncooperative scroll")
        let restoreGate = PreparedTestGate("Scroll cancellation cleanup")
        driver.scrollGate = scrollGate
        driver.restoreGate = restoreGate
        let frame = try image()
        var acquisitions = 0
        let coordinator = ScrollCaptureCoordinator(region: region(),
            timing: ScrollCaptureTiming(settlingDelay: .zero, stabilityDelay: .zero), acquire: { _ in
                acquisitions += 1
                return ScrollCaptureFrame(image: frame)
            }, driver: driver)
        _ = try await coordinator.start()
        let work = Task { @MainActor in try await coordinator.runAutomatic { _, _ in } }
        await fulfillment(of: [scrollGate.entered], timeout: 1)
        work.cancel()
        XCTAssertEqual(driver.restorations, 0)
        await assertStillOperating(coordinator)
        scrollGate.release()
        await fulfillment(of: [restoreGate.entered], timeout: 1)
        await assertStillOperating(coordinator)
        restoreGate.release()
        do { try await work.value; XCTFail("Cancelled scroll must not continue acquisition") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(acquisitions, 1)
        XCTAssertEqual(driver.restorations, 1)
        XCTAssertEqual(driver.restoreReturns, 1)
    }

    // Break: an ordinary loop error ends ownership before asynchronous cleanup or replaces the error.
    func testLoopFailureAwaitsCleanupExactlyOnceBeforeReturningOriginalError() async throws {
        let driver = AsyncOwnershipDriver()
        driver.scrollFailure = true
        let gate = PreparedTestGate("Loop-error cleanup")
        driver.restoreGate = gate
        let coordinator = try coordinator(driver: driver)
        _ = try await coordinator.start()
        let work = Task { @MainActor in try await coordinator.runAutomatic { _, _ in } }
        await fulfillment(of: [gate.entered], timeout: 1)
        await assertStillOperating(coordinator)
        gate.release()
        do { try await work.value; XCTFail("Original loop error must escape") }
        catch { XCTAssertEqual(error as? OwnershipFailure, .scroll) }
        XCTAssertEqual(driver.restorations, 1)
        XCTAssertEqual(driver.restoreReturns, 1)
        let result = try await coordinator.finish()
        XCTAssertEqual(result.image.height, 240)
    }

    // Break: invalidation suppresses restoration or resumes capture after a pending begin returns.
    func testInvalidationDuringBeginStillDrainsButNeverResumesCapture() async throws {
        let driver = AsyncOwnershipDriver()
        let beginGate = PreparedTestGate("Invalidated begin")
        let restoreGate = PreparedTestGate("Invalidated cleanup")
        driver.beginGate = beginGate
        driver.restoreGate = restoreGate
        let coordinator = try coordinator(driver: driver)
        _ = try await coordinator.start()
        let work = Task { @MainActor in try await coordinator.runAutomatic { _, _ in } }
        await fulfillment(of: [beginGate.entered], timeout: 1)
        coordinator.invalidate()
        beginGate.release()
        await fulfillment(of: [restoreGate.entered], timeout: 1)
        XCTAssertEqual(driver.restoreReturns, 0)
        restoreGate.release()
        do { try await work.value; XCTFail("Invalidated begin must stop") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(driver.scrolls, 0)
        XCTAssertEqual(driver.restoreReturns, 1)
        do { _ = try await coordinator.finish(); XCTFail("An invalidated partial must not publish") } catch {}
    }

    // Break: successful noncooperative validation resumes acquisition after invalidation.
    func testInvalidationDuringValidationDrainsWithoutAcquiringAnotherFrame() async throws {
        let driver = AsyncOwnershipDriver()
        let validationGate = PreparedTestGate("Noncooperative validation")
        let restoreGate = PreparedTestGate("Validation cleanup")
        driver.validationGate = validationGate
        driver.restoreGate = restoreGate
        defer { validationGate.release(); restoreGate.release() }
        let frame = try image()
        var acquisitions = 0
        let coordinator = ScrollCaptureCoordinator(region: region(),
            timing: ScrollCaptureTiming(settlingDelay: .zero, stabilityDelay: .zero), acquire: { _ in
                acquisitions += 1
                return ScrollCaptureFrame(image: frame)
            }, driver: driver)
        _ = try await coordinator.start()
        let work = Task { @MainActor in try await coordinator.runAutomatic { _, _ in } }
        await fulfillment(of: [validationGate.entered], timeout: 1)
        coordinator.invalidate()
        XCTAssertEqual(driver.restorations, 0)
        validationGate.release()
        await fulfillment(of: [restoreGate.entered], timeout: 1)
        XCTAssertEqual(acquisitions, 1, "No acquisition may follow a stale awaited validation")
        XCTAssertEqual(driver.restoreReturns, 0)
        restoreGate.release()
        do { try await work.value; XCTFail("Invalidation must stop automatic capture") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(driver.restorations, 1)
        XCTAssertEqual(driver.restoreReturns, 1)
    }

    private func assertStillOperating(_ coordinator: ScrollCaptureCoordinator,
                                      file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await coordinator.finish(); XCTFail("Finish must wait for cleanup", file: file, line: line) } catch {}
        do { _ = try await coordinator.addManualFrame(); XCTFail("Acquisition must wait for cleanup", file: file, line: line) } catch {}
    }

    private func coordinator(driver: AsyncOwnershipDriver, maximumFrames: Int = 40) throws -> ScrollCaptureCoordinator {
        let frame = try image()
        return ScrollCaptureCoordinator(region: region(), limits: ScrollCaptureLimits(maximumFrames: maximumFrames),
            timing: ScrollCaptureTiming(settlingDelay: .zero, stabilityDelay: .zero),
            acquire: { _ in ScrollCaptureFrame(image: frame) }, driver: driver)
    }

    private func region() -> ScrollCaptureRegion {
        ScrollCaptureRegion(displayID: 1, displayFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            rect: CGRect(x: 100, y: 100, width: 96, height: 240))
    }

    private func image() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 96, height: 240, bitsPerComponent: 8,
            bytesPerRow: 96 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 96, height: 240))
        return try XCTUnwrap(context.makeImage())
    }
}

private enum OwnershipFailure: Error, Equatable { case begin, scroll }

@MainActor
private final class AsyncOwnershipDriver: ScrollCaptureDriving {
    var beginGate: PreparedTestGate?
    var scrollGate: PreparedTestGate?
    var validationGate: PreparedTestGate?
    var restoreGate: PreparedTestGate?
    var beginFailure = false
    var scrollFailure = false
    private(set) var begins = 0
    private(set) var scrolls = 0
    private(set) var restorations = 0
    private(set) var restoreReturns = 0
    func begin(in region: ScrollCaptureRegion) async throws {
        begins += 1
        await beginGate?.wait()
        if beginFailure { throw OwnershipFailure.begin }
    }
    func validateTarget() async throws { await validationGate?.wait() }
    func scrollDown(points: CGFloat) async throws {
        scrolls += 1
        await scrollGate?.wait()
        if scrollFailure { throw OwnershipFailure.scroll }
    }
    func recordObservedMovement(points: CGFloat?) {}
    func restore() async -> String? {
        restorations += 1
        await restoreGate?.wait()
        restoreReturns += 1
        return nil
    }
}
