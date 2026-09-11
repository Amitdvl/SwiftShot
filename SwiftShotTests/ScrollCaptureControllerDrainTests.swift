import AppKit
import SwiftUI
import XCTest
@testable import SwiftShot

/// Exercises real controller task ownership with noncooperative external-work
/// gates. No accessibility lookup, screen capture, pointer move or event posting.
@MainActor
final class ScrollCaptureControllerDrainTests: XCTestCase {
    // Break: cancelAndWait finishes when cancellation is requested, or cleanup
    // is launched in a detached task after the owning operation returns.
    func testCancelAndWaitRetainsOwnershipThroughNoncooperativeRestore() async throws {
        let fixture = try Fixture()
        do {
            fixture.start(tag: 20)
            try await waitUntil { fixture.original.scrollGate.entered }

            let completion = Completion()
            let prematureCompletion = expectation(description: "Cancel waiter returned before restoration returned")
            prematureCompletion.isInverted = true
            let waiter = Task { @MainActor in
                completion.started = true
                await fixture.controller.cancelAndWait()
                if fixture.original.restoreReturns != 1 { prematureCompletion.fulfill() }
                completion.finished = true
            }
            defer { waiter.cancel() }
            try await waitUntil { completion.started }
            XCTAssertFalse(completion.finished)
            XCTAssertFalse(fixture.controller.isActive)
            XCTAssertEqual(fixture.original.restoreCalls, 0)

            fixture.original.scrollGate.release()
            try await waitUntil { fixture.original.restoreGate.entered }
            await fulfillment(of: [prematureCompletion], timeout: 0.2)
            XCTAssertFalse(completion.finished, "A suspended restoration still owns the canceled operation")
            XCTAssertEqual(fixture.original.restoreCalls, 1)
            XCTAssertEqual(fixture.acquisitions[20, default: 0], 1)

            fixture.original.restoreGate.release()
            try await waitUntil { completion.finished }
            XCTAssertEqual(fixture.original.restoreReturns, 1)
            XCTAssertEqual(fixture.acquisitions[20, default: 0], 1)
        } catch {
            await fixture.close()
            throw error
        }
        await fixture.close()
    }

    // Break: B discards its canceled wait on A, so C starts acquisition before
    // A's asynchronous cleanup has relinquished native-operation ownership.
    func testReplacementChainWaitsForOriginalRestorationBeforeAcquiring() async throws {
        let fixture = try Fixture()
        do {
            fixture.start(tag: 20)
            try await waitUntil { fixture.original.scrollGate.entered }

            let prematureAcquisition = expectation(description: "Replacement acquired while old cleanup was held")
            prematureAcquisition.isInverted = true
            fixture.onAcquisition = { tag in
                if tag != 20 {
                    XCTAssertEqual(fixture.original.restoreReturns, 1,
                        "Replacement acquisition must follow actual cleanup return, not just gate release")
                    if fixture.original.restoreReturns != 1 { prematureAcquisition.fulfill() }
                }
            }
            fixture.start(tag: 100)
            fixture.start(tag: 180)
            let replacementRoot = try fixture.currentRoot()
            // This test exercises replacement ownership; keep the replacement
            // session in its manual fallback so its first frame is the only
            // acquisition after the original cleanup returns.
            replacementRoot.model.automaticDisabled = true
            XCTAssertTrue(replacementRoot.model.busy)

            fixture.original.scrollGate.release()
            try await waitUntil { fixture.original.restoreGate.entered }
            // The gate cannot open during this bounded negative observation.
            // This exceeds the real controller's 60ms acquisition delay; a
            // replacement that incorrectly starts work has time to expose it.
            await fulfillment(of: [prematureAcquisition], timeout: 0.2)
            XCTAssertEqual(fixture.acquisitions[100, default: 0], 0)
            XCTAssertEqual(fixture.acquisitions[180, default: 0], 0)
            XCTAssertTrue(replacementRoot.model.busy)

            fixture.original.restoreGate.release()
            try await waitUntil { !replacementRoot.model.busy }
            XCTAssertEqual(fixture.original.restoreReturns, 1)
            XCTAssertEqual(fixture.acquisitions[20, default: 0], 1)
            XCTAssertEqual(fixture.acquisitions[100, default: 0], 0)
            XCTAssertEqual(fixture.acquisitions[180, default: 0], 1)
            XCTAssertFalse(replacementRoot.model.acquisitionDisabled)
            replacementRoot.addFrame()
            try await waitUntil { !replacementRoot.model.busy }
            XCTAssertEqual(fixture.acquisitions[180, default: 0], 2)
            XCTAssertEqual(fixture.drivers.map(\.beginCalls), [1, 0, 0])
        } catch {
            await fixture.close()
            throw error
        }
        await fixture.close()
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        guard condition() else {
            XCTFail("The controller did not reach the required ownership boundary")
            throw DrainTestFailure.timedOut
        }
    }

    private enum DrainTestFailure: Error { case timedOut }

    @MainActor
    private final class Completion {
        var started = false
        var finished = false
    }

    @MainActor
    private final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private(set) var entered = false
        private(set) var released = false
        func wait() async {
            entered = true
            if released { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func release() {
            released = true
            let pending = continuation
            continuation = nil
            pending?.resume()
        }
    }

    @MainActor
    private final class DeferredDriver: ScrollCaptureDriving {
        let scrollGate = Gate()
        let restoreGate = Gate()
        var beginCalls = 0
        var restoreCalls = 0
        var restoreReturns = 0
        func begin(in region: ScrollCaptureRegion) async throws { beginCalls += 1 }
        func validateTarget() async throws { try Task.checkCancellation() }
        func scrollDown(points: CGFloat) async throws { await scrollGate.wait() }
        func recordObservedMovement(points: CGFloat?) {}
        func restore() async -> String? {
            restoreCalls += 1
            await restoreGate.wait()
            restoreReturns += 1
            return nil
        }
    }

    @MainActor
    private final class Fixture {
        let image: CGImage
        let priorWindows: Set<ObjectIdentifier>
        var acquisitions: [Int: Int] = [:]
        var drivers: [DeferredDriver] = []
        var onAcquisition: ((Int) -> Void)?
        var original: DeferredDriver { drivers[0] }
        lazy var controller = ScrollCaptureController(acquire: { [weak self] region in
            guard let self else { throw CancellationError() }
            let tag = Int(region.rect.minX)
            self.acquisitions[tag, default: 0] += 1
            self.onAcquisition?(tag)
            return ScrollCaptureFrame(image: self.image)
        }, makeDriver: { [unowned self] in
            let driver = DeferredDriver()
            self.drivers.append(driver)
            return driver
        })

        init() throws {
            priorWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
            let context = try XCTUnwrap(CGContext(data: nil, width: 100, height: 100,
                bitsPerComponent: 8, bytesPerRow: 400,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
            image = try XCTUnwrap(context.makeImage())
        }

        func start(tag: Int) {
            controller.start(region: ScrollCaptureRegion(displayID: 1,
                displayFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                rect: CGRect(x: tag, y: 100, width: 100, height: 100)), onResult: { _ in
                    XCTFail("The fixture did not request Finish")
                })
        }

        func currentRoot() throws -> ScrollCapturePanelView {
            let panel = try XCTUnwrap(NSApp.windows.first {
                !priorWindows.contains(ObjectIdentifier($0)) && $0.title == "Scrolling Capture" && $0.isVisible
            })
            return try XCTUnwrap(panel.contentView as? NSHostingView<ScrollCapturePanelView>).rootView
        }

        func close() async {
            onAcquisition = nil
            for driver in drivers { driver.scrollGate.release(); driver.restoreGate.release() }
            await controller.cancelAndWait()
            // Test teardown also drains a deliberately broken controller. Do not
            // leak fixture tasks into another test when an ownership assertion fails.
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while drivers.contains(where: { $0.beginCalls > 0 && $0.restoreReturns == 0 }),
                  ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertTrue(drivers.allSatisfy { $0.beginCalls == 0 || $0.restoreReturns == 1 },
                "Every started fixture operation must finish its single cleanup")
        }
    }
}
