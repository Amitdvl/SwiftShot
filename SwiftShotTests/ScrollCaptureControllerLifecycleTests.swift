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

    // CleanShot-style Auto must publish the verified result directly instead
    // of leaving a second Finish action in the way after the native end signal.
    func testVerifiedAutomaticCaptureFinishesWithoutAnExtraClick() async throws {
        let fixture = try AutomaticFinishFixture()
        do {
            fixture.start()
            try await waitUntil { fixture.result != nil }

            let result = try XCTUnwrap(fixture.result)
            XCTAssertTrue(result.isComplete)
            XCTAssertTrue(result.warnings.isEmpty)
            XCTAssertEqual(result.image.height, 310)
            XCTAssertFalse(fixture.controller.isActive)
            XCTAssertEqual(fixture.driver.scrolls, 1)
        } catch {
            await fixture.controller.cancelAndWait()
            throw error
        }
        await fixture.controller.cancelAndWait()
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

    @MainActor
    private final class AutomaticFinishFixture {
        let driver = EndDriver()
        private var frames: [ScrollCaptureFrame]
        private var nextFrame = 0
        var result: ScrollCaptureResult?
        lazy var controller = ScrollCaptureController(acquire: { [unowned self] _ in
            defer { nextFrame += 1 }
            guard nextFrame < frames.count else { throw ScrollCaptureIssue.noFrames }
            return frames[nextFrame]
        }, makeDriver: { [unowned self] in driver })

        init() throws {
            let first = ScrollCaptureFrame(image: try Self.image(offset: 0))
            let moved = ScrollCaptureFrame(image: try Self.image(offset: 70))
            frames = [first, moved, moved]
        }

        func start() {
            controller.start(region: ScrollCaptureRegion(displayID: 1,
                displayFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                rect: CGRect(x: 100, y: 100, width: 96, height: 240)), onResult: { [weak self] result in
                    self?.result = result
                })
        }

        private static func image(offset: Int) throws -> CGImage {
            let width = 96
            let height = 240
            var bytes = [UInt8](repeating: 255, count: width * height * 4)
            for y in 0..<height {
                for x in 0..<width {
                    let index = (y * width + x) * 4
                    let value = UInt32(truncatingIfNeeded: (offset + y + 17) &* 48_271 ^ (x + 31) &* 69_621)
                    bytes[index] = UInt8(truncatingIfNeeded: value)
                    bytes[index + 1] = UInt8(truncatingIfNeeded: value >> 8)
                    bytes[index + 2] = UInt8(truncatingIfNeeded: value >> 16)
                }
            }
            let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
            return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        }
    }

    @MainActor
    private final class EndDriver: ScrollCaptureDriving {
        private(set) var scrolls = 0
        func begin(in region: ScrollCaptureRegion) async throws {}
        func validateTarget() async throws {}
        func scrollDown(points: CGFloat) async throws { scrolls += 1 }
        func recordObservedMovement(points: CGFloat?) {}
        func isAtEndOfContent() -> Bool? { scrolls >= 1 }
        func restore() async -> String? { nil }
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
