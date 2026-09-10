import XCTest
import AppKit
import CoreGraphics
@testable import SwiftShot

final class ScrollStitcherTests: XCTestCase {
    func testMemoryAdmissionReservesBothFlatteningBuffers() async throws {
        let stitcher = ScrollStitcher(limits: ScrollCaptureLimits(maximumMemoryBytes: 740_000))
        for offset in [0, 100, 200] {
            let report = try await stitcher.append(ScrollCaptureFrame(image: image(width: 100, height: 240, offset: offset)))
            XCTAssertNotEqual(report.disposition, .rejected)
        }
        let report = try await stitcher.append(ScrollCaptureFrame(image: image(width: 100, height: 240, offset: 300)))
        XCTAssertEqual(report.issue, .memoryLimit)
        let result = try await stitcher.render().image
        XCTAssertEqual(result.height, 440)
    }

    func testFullPixelComparisonChecksCancellation() async throws {
        let buffer = try ScrollCapturePixels(image: image(width: 1000, height: 1000, offset: 0))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try buffer.matchFraction(other: buffer, fromRow: 0, otherFromRow: 0, rowCount: buffer.height)
        }
        do { _ = try await task.value; XCTFail("Pixel comparison must observe cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testManualOverlappingFramesProduceExactContinuousPixels() async throws {
        let stitcher = ScrollStitcher()
        let first = try image(width: 96, height: 240, offset: 0)
        let second = try image(width: 96, height: 240, offset: 90)
        _ = try await stitcher.append(ScrollCaptureFrame(image: first))
        let report = try await stitcher.append(ScrollCaptureFrame(image: second))
        XCTAssertEqual(report.disposition, .appended)
        XCTAssertEqual(report.addedRows, 90)
        let result = try await stitcher.render().image
        XCTAssertEqual(result.height, 330)
        XCTAssertEqual(try pixels(result), try pixels(image(width: 96, height: 330, offset: 0)))
    }

    func testMultipleUnevenScrollStepsStayPixelAligned() async throws {
        let stitcher = ScrollStitcher()
        for offset in [0, 57, 143, 201] {
            let frame = try image(width: 80, height: 240, offset: offset)
            let report = try await stitcher.append(ScrollCaptureFrame(image: frame))
            XCTAssertNotEqual(report.disposition, .rejected)
        }
        let result = try await stitcher.render().image
        XCTAssertEqual(result.height, 441)
        XCTAssertEqual(try pixels(result), try pixels(image(width: 80, height: 441, offset: 0)))
    }

    func testStickyHeaderAndFooterAppearOnlyOnce() async throws {
        let stitcher = ScrollStitcher()
        for offset in [0, 83, 151] {
            _ = try await stitcher.append(ScrollCaptureFrame(image: image(width: 96, height: 240, offset: offset, header: 20, footer: 15)))
        }
        let result = try await stitcher.render().image
        XCTAssertEqual(result.height, 391)
        let expected = try image(width: 96, height: 391, offset: 0, header: 20, footer: 15)
        XCTAssertEqual(try pixels(result), try pixels(expected))
    }

    func testUnchangedFrameDoesNotDuplicateContent() async throws {
        let stitcher = ScrollStitcher()
        let frame = ScrollCaptureFrame(image: try image(width: 96, height: 240, offset: 0))
        _ = try await stitcher.append(frame)
        let report = try await stitcher.append(frame)
        XCTAssertEqual(report.disposition, .unchanged)
        let statistics = await stitcher.statistics()
        XCTAssertEqual(statistics.frameCount, 1)
        XCTAssertEqual(statistics.outputHeight, 240)
    }

    func testRepeatedPatternRefusesAmbiguousOffsetWithoutChangingResult() async throws {
        let stitcher = ScrollStitcher()
        _ = try await stitcher.append(ScrollCaptureFrame(image: image(width: 96, height: 240, offset: 0, repeatRows: 40)))
        let report = try await stitcher.append(ScrollCaptureFrame(image: image(width: 96, height: 240, offset: 13, repeatRows: 40)))
        XCTAssertEqual(report.disposition, .rejected)
        XCTAssertEqual(report.issue, .ambiguousContent)
        let statistics = await stitcher.statistics()
        XCTAssertEqual(statistics.outputHeight, 240)
    }

    func testDynamicContentRejectsASeeminglyGoodPartialOverlap() async throws {
        let stitcher = ScrollStitcher()
        _ = try await stitcher.append(ScrollCaptureFrame(image: image(width: 96, height: 240, offset: 0)))
        let report = try await stitcher.append(ScrollCaptureFrame(image: image(width: 96, height: 240, offset: 70, corruptRows: 40..<70)))
        XCTAssertEqual(report.disposition, .rejected)
        XCTAssertEqual(report.issue, .dynamicContent)
        let statistics = await stitcher.statistics()
        XCTAssertEqual(statistics.frameCount, 1)
    }

    func testInsufficientOverlapRefusesGap() async throws {
        let stitcher = ScrollStitcher()
        _ = try await stitcher.append(ScrollCaptureFrame(image: image(width: 96, height: 240, offset: 0)))
        let report = try await stitcher.append(ScrollCaptureFrame(image: image(width: 96, height: 240, offset: 230)))
        XCTAssertEqual(report.disposition, .rejected)
        XCTAssertEqual(report.issue, .insufficientOverlap)
    }

    func testChangedFrameDimensionsLeaveOriginalIntact() async throws {
        let stitcher = ScrollStitcher()
        _ = try await stitcher.append(ScrollCaptureFrame(image: image(width: 96, height: 240, offset: 0)))
        let report = try await stitcher.append(ScrollCaptureFrame(image: image(width: 97, height: 240, offset: 90)))
        XCTAssertEqual(report.disposition, .rejected)
        XCTAssertEqual(report.issue, .dimensionsChanged)
        let result = try await stitcher.render().image
        XCTAssertEqual(result.width, 96)
    }

    func testFrameLimitStopsBeforeRetainingAdditionalFrame() async throws {
        let stitcher = ScrollStitcher(limits: ScrollCaptureLimits(maximumFrames: 2))
        for offset in [0, 70] {
            _ = try await stitcher.append(ScrollCaptureFrame(image: image(width: 96, height: 240, offset: offset)))
        }
        let report = try await stitcher.append(ScrollCaptureFrame(image: image(width: 96, height: 240, offset: 140)))
        XCTAssertEqual(report.issue, .frameLimit)
        let statistics = await stitcher.statistics()
        XCTAssertEqual(statistics.frameCount, 2)
        let canAcquire = await stitcher.canAcquireAnotherFrame()
        XCTAssertFalse(canAcquire)
    }

    func testOutputLimitStopsBeforeGrowingCanvas() async throws {
        let stitcher = ScrollStitcher(limits: ScrollCaptureLimits(maximumOutputPixels: 30_000))
        _ = try await stitcher.append(ScrollCaptureFrame(image: image(width: 96, height: 240, offset: 0)))
        let report = try await stitcher.append(ScrollCaptureFrame(image: image(width: 96, height: 240, offset: 100)))
        XCTAssertEqual(report.issue, .outputLimit)
        let statistics = await stitcher.statistics()
        XCTAssertEqual(statistics.outputHeight, 240)
    }

    func testMemoryLimitAccountsForSourceFramesAndFinalCanvas() async throws {
        let stitcher = ScrollStitcher(limits: ScrollCaptureLimits(maximumMemoryBytes: 500_000))
        _ = try await stitcher.append(ScrollCaptureFrame(image: image(width: 96, height: 240, offset: 0)))
        let report = try await stitcher.append(ScrollCaptureFrame(image: image(width: 96, height: 240, offset: 90)))
        XCTAssertEqual(report.issue, .memoryLimit)
        let statistics = await stitcher.statistics()
        XCTAssertEqual(statistics.frameCount, 1)
    }

    @MainActor
    func testTerminalAcquisitionStopBlocksNewFramesButAllowsPartialFinish() async throws {
        let frame = ScrollCaptureFrame(image: try image(width: 96, height: 240, offset: 0))
        let frames = ScrollTestFrameQueue([frame, frame])
        let driver = ScrollTestDriver()
        let coordinator = ScrollCaptureCoordinator(region: testRegion(), acquire: { _ in try frames.next() }, driver: driver)
        _ = try await coordinator.start()
        coordinator.preventFurtherAcquisition(reason: "Display changed")
        do { _ = try await coordinator.addManualFrame(); XCTFail("Terminal stop must reject new acquisition") } catch {}
        do { try await coordinator.runAutomatic { _, _ in }; XCTFail("Terminal stop must reject Auto") } catch {}
        XCTAssertEqual(frames.acquisitions, 1)
        XCTAssertEqual(driver.begins, 0)
        let result = try await coordinator.finish()
        XCTAssertEqual(result.image.height, 240)
        XCTAssertFalse(result.isComplete)
    }

    @MainActor
    func testNativeTargetReplacementPreventsForwardAndReverseEvents() async throws {
        let environment = ScrollTestNativeEnvironment()
        let driver = NativeScrollCaptureDriver(environment: environment)
        try await driver.begin(in: testRegion())
        try await driver.scrollDown(points: 80)
        driver.recordObservedMovement(points: 80)
        environment.targetIsCurrent = false
        do { try await driver.scrollDown(points: 80); XCTFail("Changed target must reject forward events") } catch {}
        let notice = await driver.restore()
        XCTAssertEqual(environment.events, [-80])
        XCTAssertTrue(notice?.contains("target changed") == true)
        XCTAssertEqual(environment.pointerMoves, [CGPoint(x: 100, y: 100)], "Loss must leave the user's pointer alone")
        XCTAssertEqual(environment.focusRestorations, 0, "Loss must not steal focus back")
    }

    @MainActor
    func testNativeTargetReplacementBeforeFirstWheelPostsNothing() async throws {
        let environment = ScrollTestNativeEnvironment()
        let driver = NativeScrollCaptureDriver(environment: environment)
        try await driver.begin(in: testRegion())
        environment.targetIsCurrent = false
        do { try await driver.scrollDown(points: 80); XCTFail("Changed target must reject forward events") } catch {}
        _ = await driver.restore()
        XCTAssertTrue(environment.events.isEmpty)
    }

    @MainActor
    func testAutomaticTargetReplacementAfterWheelCannotAppendForeignMatchingFrames() async throws {
        let initial = ScrollCaptureFrame(image: try image(width: 96, height: 240, offset: 0))
        // A replacement window can share a legitimate-looking overlap. Pixel
        // matching must not override the original native window identity.
        let foreign = ScrollCaptureFrame(image: try image(width: 96, height: 240, offset: 100))
        let frames = ScrollTestFrameQueue([initial, foreign, foreign])
        let environment = ScrollTestNativeEnvironment()
        environment.invalidateTargetAfterWheel = true
        let driver = NativeScrollCaptureDriver(environment: environment)
        let coordinator = ScrollCaptureCoordinator(region: testRegion(),
            timing: ScrollCaptureTiming(settlingDelay: .zero, stabilityDelay: .zero),
            acquire: { _ in try frames.next() }, driver: driver)
        _ = try await coordinator.start()
        do {
            try await coordinator.runAutomatic { _, _ in }
            XCTFail("A replaced automatic target must stop acquisition")
        } catch {}
        let statistics = await coordinator.statistics()
        XCTAssertEqual(statistics.frameCount, 1, "Foreign rows must never enter the accepted partial")
        let result = try await coordinator.finish()
        XCTAssertEqual(result.image.height, 240)
        XCTAssertEqual(try pixels(result.image), try pixels(initial.image))
        XCTAssertFalse(result.isComplete)
        XCTAssertEqual(environment.events.count, 1, "No further wheel or restoration event may reach a replaced target")
        XCTAssertEqual(environment.focusRestorations, 0, "Foreign target must not cause focus restoration")
    }

    func testPanelPlacementKeepsAutomaticEventTargetUncovered() throws {
        let visible = CGRect(x: 0, y: 0, width: 1024, height: 768)
        let selected = CGRect(x: 0, y: 468, width: 700, height: 300)
        let frame = try XCTUnwrap(ScrollCapturePanelPlacement.frame(selected: selected, visible: visible,
            panelSize: CGSize(width: 384, height: 252)))
        XCTAssertFalse(frame.insetBy(dx: -16, dy: -16).contains(CGPoint(x: selected.midX, y: selected.midY)))
        XCTAssertTrue(visible.contains(frame))
    }

    func testPanelPlacementDisablesAutoWhenNoSafeFrameFits() {
        XCTAssertNil(ScrollCapturePanelPlacement.frame(selected: CGRect(x: 0, y: 0, width: 200, height: 100),
            visible: CGRect(x: 0, y: 0, width: 200, height: 100), panelSize: CGSize(width: 384, height: 252)))
    }

    @MainActor
    func testManualCoordinatorDoesNotScrollAndReturnsVerifiedResult() async throws {
        let frames = ScrollTestFrameQueue([
            ScrollCaptureFrame(image: try image(width: 96, height: 240, offset: 0)),
            ScrollCaptureFrame(image: try image(width: 96, height: 240, offset: 70))
        ])
        let driver = ScrollTestDriver()
        let coordinator = ScrollCaptureCoordinator(region: testRegion(), acquire: { _ in try frames.next() }, driver: driver)
        _ = try await coordinator.start()
        let report = try await coordinator.addManualFrame()
        XCTAssertEqual(report.disposition, .appended)
        let result = try await coordinator.finish()
        XCTAssertEqual(result.image.height, 310)
        XCTAssertTrue(result.isComplete)
        XCTAssertTrue(result.warnings.isEmpty)
        XCTAssertEqual(driver.begins, 0)
        XCTAssertEqual(driver.scrolls, 0)
    }

    @MainActor
    func testAutomaticCoordinatorChecksStablePairsAndStopsWithExplicitEndUncertainty() async throws {
        let initial = ScrollCaptureFrame(image: try image(width: 96, height: 240, offset: 0))
        let moved = ScrollCaptureFrame(image: try image(width: 96, height: 240, offset: 70))
        let frames = ScrollTestFrameQueue([initial, moved, moved, moved, moved])
        let driver = ScrollTestDriver()
        let coordinator = ScrollCaptureCoordinator(region: testRegion(),
            timing: ScrollCaptureTiming(settlingDelay: .zero, stabilityDelay: .zero),
            acquire: { _ in try frames.next() }, driver: driver)
        _ = try await coordinator.start()
        try await coordinator.runAutomatic { _, _ in }
        let result = try await coordinator.finish()
        XCTAssertEqual(result.image.height, 310)
        XCTAssertFalse(result.isComplete)
        XCTAssertFalse(result.warnings.isEmpty)
        XCTAssertEqual(driver.begins, 1)
        XCTAssertEqual(driver.scrolls, 2)
        XCTAssertEqual(driver.restorations, 1)
        XCTAssertEqual(driver.observedMovements.compactMap { $0 }, [70, 0])
    }

    @MainActor
    func testAutomaticCoordinatorRejectsUnsettledFrameAndRestoresDriver() async throws {
        let frames = ScrollTestFrameQueue([
            ScrollCaptureFrame(image: try image(width: 96, height: 240, offset: 0)),
            ScrollCaptureFrame(image: try image(width: 96, height: 240, offset: 70)),
            ScrollCaptureFrame(image: try image(width: 96, height: 240, offset: 70, corruptRows: 40..<70))
        ])
        let driver = ScrollTestDriver()
        let coordinator = ScrollCaptureCoordinator(region: testRegion(),
            timing: ScrollCaptureTiming(settlingDelay: .zero, stabilityDelay: .zero),
            acquire: { _ in try frames.next() }, driver: driver)
        _ = try await coordinator.start()
        try await coordinator.runAutomatic { _, _ in }
        let result = try await coordinator.finish()
        XCTAssertEqual(result.image.height, 240)
        XCTAssertFalse(result.isComplete)
        XCTAssertEqual(driver.restorations, 1)
    }

    @MainActor
    func testAutomaticCancellationRestoresAndLeavesPriorFramesFinishable() async throws {
        let first = ScrollCaptureFrame(image: try image(width: 96, height: 240, offset: 0))
        let driver = ScrollTestDriver()
        driver.blockScroll = true
        let coordinator = ScrollCaptureCoordinator(region: testRegion(), acquire: { _ in first }, driver: driver)
        _ = try await coordinator.start()
        let task = Task { try await coordinator.runAutomatic { _, _ in } }
        for _ in 0..<100 {
            if driver.begins > 0 { break }
            await Task.yield()
        }
        XCTAssertEqual(driver.begins, 1)
        task.cancel()
        do { try await task.value; XCTFail("Cancelled automatic capture must stop") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(driver.restorations, 1)
        let result = try await coordinator.finish()
        XCTAssertEqual(result.image.height, 240)
    }

    @MainActor
    func testInvalidatedCoordinatorNeverPublishesOrAcquiresMoreFrames() async throws {
        let frame = ScrollCaptureFrame(image: try image(width: 96, height: 240, offset: 0))
        let frames = ScrollTestFrameQueue([frame])
        let coordinator = ScrollCaptureCoordinator(region: testRegion(), acquire: { _ in try frames.next() }, driver: ScrollTestDriver())
        _ = try await coordinator.start()
        coordinator.invalidate()
        do { _ = try await coordinator.addManualFrame(); XCTFail("Invalidated acquisition must fail") }
        catch { XCTAssertTrue(error is CancellationError) }
        do { _ = try await coordinator.finish(); XCTFail("Invalidated result must not publish") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(frames.acquisitions, 1)
    }

    private func testRegion() -> ScrollCaptureRegion {
        ScrollCaptureRegion(displayID: 1, displayFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            rect: CGRect(x: 100, y: 100, width: 96, height: 240))
    }

    private func image(width: Int, height: Int, offset: Int, header: Int = 0, footer: Int = 0,
                       repeatRows: Int? = nil, corruptRows: Range<Int>? = nil) throws -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let sourceY = repeatRows.map { (offset + y - header) % $0 } ?? (offset + y - header)
                let index = (y * width + x) * 4
                let hash = UInt32(truncatingIfNeeded: (x + 11) &* 73_856_093 ^ (sourceY + 41) &* 19_349_663)
                if y < header { bytes[index] = 17; bytes[index + 1] = UInt8(x); bytes[index + 2] = 191 }
                else if y >= height - footer { bytes[index] = 199; bytes[index + 1] = UInt8(x); bytes[index + 2] = 23 }
                else {
                    bytes[index] = UInt8(truncatingIfNeeded: hash)
                    bytes[index + 1] = UInt8(truncatingIfNeeded: hash >> 9)
                    bytes[index + 2] = UInt8(truncatingIfNeeded: hash >> 17)
                    if corruptRows?.contains(y) == true { bytes[index] ^= 255; bytes[index + 1] ^= 255; bytes[index + 2] ^= 255 }
                }
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func pixels(_ image: CGImage) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try XCTUnwrap(context.data), count: image.width * image.height * 4)
    }
}

@MainActor
private final class ScrollTestFrameQueue {
    private var frames: [ScrollCaptureFrame]
    private(set) var acquisitions = 0
    init(_ frames: [ScrollCaptureFrame]) { self.frames = frames }
    func next() throws -> ScrollCaptureFrame {
        guard !frames.isEmpty else { throw ScrollCaptureIssue.noFrames }
        acquisitions += 1
        return frames.removeFirst()
    }
}

@MainActor
private final class ScrollTestDriver: ScrollCaptureDriving {
    var begins = 0
    var scrolls = 0
    var restorations = 0
    var observedMovements: [CGFloat?] = []
    var blockScroll = false
    func begin(in region: ScrollCaptureRegion) async throws { begins += 1 }
    func validateTarget() async throws {}
    func scrollDown(points: CGFloat) async throws {
        scrolls += 1
        if blockScroll { try await Task.sleep(for: .seconds(10)) }
    }
    func recordObservedMovement(points: CGFloat?) { observedMovements.append(points) }
    func restore() async -> String? { restorations += 1; return nil }
}

@MainActor
private final class ScrollTestNativeEnvironment: NativeScrollCaptureEnvironment {
    var targetIsCurrent = true
    var invalidateTargetAfterWheel = false
    var events: [Int32] = []
    var pointerMoves: [CGPoint] = []
    var focusRestorations = 0
    var pointer = CGPoint(x: 3, y: 4)
    func resolveTarget(in region: ScrollCaptureRegion) async throws -> NativeScrollCaptureTarget {
        let id = UUID()
        return NativeScrollCaptureTarget(id: id, point: CGPoint(x: 100, y: 100), ownerPID: 123) { purpose in
            NativeScrollCaptureReceipt(targetID: id, point: CGPoint(x: 100, y: 100), ownerPID: 123,
                purpose: purpose, deadline: ContinuousClock.now.advanced(by: .milliseconds(200)),
                now: { ContinuousClock.now }, isCurrent: { self.targetIsCurrent })
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
                if self.invalidateTargetAfterWheel { self.targetIsCurrent = false }
            }).post(delta, using: receipt, restoring: restoring)
    }
}
