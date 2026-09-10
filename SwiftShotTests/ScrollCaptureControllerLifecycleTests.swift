import AppKit
import SwiftUI
import XCTest
@testable import SwiftShot

/// Real controller, coordinator, panel and button actions; only image acquisition
/// is synthetic. These tests post process-local notifications, not OS events,
/// and never start the native input driver or request screen-capture permission.
@MainActor
final class ScrollCaptureControllerLifecycleTests: XCTestCase {
    // Break: a queued old-session observer closes over self without its session
    // identity, so it disables the replacement before that session can acquire.
    func testQueuedOldDisplayNotificationDoesNotStopReplacement() async throws {
        try await assertOldNotificationDoesNotStopReplacement(.display)
    }

    func testQueuedOldSleepNotificationDoesNotStopReplacement() async throws {
        try await assertOldNotificationDoesNotStopReplacement(.sleep)
    }

    // Positive controls: ignoring every notification would protect replacement
    // sessions but leave a current session capturing through a terminal change.
    func testCurrentDisplayNotificationStopsFurtherAcquisition() async throws {
        try await assertCurrentNotificationStopsAcquisition(.display)
    }

    func testCurrentSleepNotificationStopsFurtherAcquisition() async throws {
        try await assertCurrentNotificationStopsAcquisition(.sleep)
    }

    private func assertOldNotificationDoesNotStopReplacement(_ event: Event) async throws {
        try await withFixture { fixture in
            fixture.start(tag: 20)
            // Observer synchronously queues its MainActor task. No suspension
            // before replacement: that task still belongs to the old session.
            event.post()
            fixture.start(tag: 180)
            let root = try fixture.currentRoot()
            try await waitUntil { !root.model.busy }

            XCTAssertFalse(root.model.acquisitionDisabled)
            XCTAssertEqual(fixture.acquisitions[180, default: 0], 1)
            XCTAssertEqual(fixture.acquisitions[20, default: 0], 0)
            root.addFrame()
            try await waitUntil { !root.model.busy }
            XCTAssertEqual(fixture.acquisitions[180, default: 0], 2,
                "The real replacement Add Frame action must remain usable")
        }
    }

    private func assertCurrentNotificationStopsAcquisition(_ event: Event) async throws {
        try await withFixture { fixture in
            fixture.start(tag: 20)
            let root = try fixture.currentRoot()
            try await waitUntil { !root.model.busy }
            XCTAssertEqual(fixture.acquisitions[20, default: 0], 1)

            event.post()
            try await waitUntil { root.model.acquisitionDisabled }
            root.addFrame()
            XCTAssertFalse(root.model.busy, "A terminally stopped session must not admit another capture task")
            try await waitUntil { !root.model.busy }
            XCTAssertEqual(fixture.acquisitions[20, default: 0], 1)
            XCTAssertTrue(root.model.acquisitionDisabled)
        }
    }

    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let fixture = try Fixture()
        do {
            try await body(fixture)
        } catch {
            await fixture.controller.cancelAndWait()
            throw error
        }
        await fixture.controller.cancelAndWait()
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), "The real controller did not reach the expected state")
    }

    private enum Event {
        case display, sleep
        func post() {
            switch self {
            case .display:
                NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
            case .sleep:
                NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
            }
        }
    }

    @MainActor
    private final class Fixture {
        let image: CGImage
        let priorWindows: Set<ObjectIdentifier>
        var acquisitions: [Int: Int] = [:]
        lazy var controller = ScrollCaptureController(acquire: { [weak self] region in
            guard let self else { throw CancellationError() }
            self.acquisitions[Int(region.rect.minX), default: 0] += 1
            return ScrollCaptureFrame(image: self.image)
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
                    XCTFail("No Finish action was requested")
                })
        }

        func currentRoot() throws -> ScrollCapturePanelView {
            let window = try XCTUnwrap(NSApp.windows.first {
                $0.isVisible && !priorWindows.contains(ObjectIdentifier($0)) &&
                    $0.contentView is NSHostingView<ScrollCapturePanelView>
            })
            return try XCTUnwrap(window.contentView as? NSHostingView<ScrollCapturePanelView>).rootView
        }
    }
}
