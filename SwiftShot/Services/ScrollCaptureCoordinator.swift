import CoreGraphics
import Foundation

@MainActor
protocol ScrollCaptureDriving: AnyObject {
    func begin(in region: ScrollCaptureRegion) async throws
    /// Rejects and latches loss of the original native window/scroll-area identity.
    func validateTarget() async throws
    func scrollDown(points: CGFloat) async throws
    /// Nil means the movement could not be established from a trustworthy overlap.
    func recordObservedMovement(points: CGFloat?)
    /// Returns true only when the native target positively reports its end
    /// position. Nil means the target does not expose trustworthy scroll
    /// metrics, so an unchanged frame remains reviewable rather than silently
    /// claiming a complete document.
    func isAtEndOfContent() -> Bool?
    /// Restores pointer/focus and requests page restoration; returns uncertainty.
    func restore() async -> String?
}

extension ScrollCaptureDriving {
    func isAtEndOfContent() -> Bool? { nil }
}

struct ScrollCaptureTiming: Sendable {
    var settlingDelay: Duration = .milliseconds(140)
    var stabilityDelay: Duration = .milliseconds(70)
}

/// Testable orchestration; it owns no windows and never writes an archive or file.
@MainActor
final class ScrollCaptureCoordinator {
    typealias Acquisition = @MainActor @Sendable (ScrollCaptureRegion) async throws -> ScrollCaptureFrame
    private let region: ScrollCaptureRegion
    private let acquire: Acquisition
    private let driver: any ScrollCaptureDriving
    private let stitcher: ScrollStitcher
    private let limits: ScrollCaptureLimits
    private let timing: ScrollCaptureTiming
    private var invalidated = false
    private var operating = false
    private var started = false
    private var acquisitionStopReason: String?
    private var nextScrollPoints: CGFloat
    private(set) var warnings: [String] = []

    init(region: ScrollCaptureRegion, limits: ScrollCaptureLimits = ScrollCaptureLimits(),
         timing: ScrollCaptureTiming = ScrollCaptureTiming(), acquire: @escaping Acquisition,
         driver: any ScrollCaptureDriving) {
        self.region = region
        self.limits = limits
        self.timing = timing
        self.acquire = acquire
        self.driver = driver
        nextScrollPoints = max(48, min(region.rect.height * 0.45, region.rect.height - 48))
        stitcher = ScrollStitcher(limits: limits)
    }

    func start() async throws -> ScrollAppendReport {
        try ensureAvailable()
        guard !started, !operating else { throw CaptureError.failed("A scrolling capture operation is already active.") }
        operating = true
        defer { operating = false }
        let frame = try await acquire(region)
        try ensureAvailable()
        let report = try await stitcher.append(frame)
        if report.disposition == .firstFrame { started = true }
        record(report)
        return report
    }

    func addManualFrame() async throws -> ScrollAppendReport {
        try ensureAvailable()
        guard started, !operating else { throw CaptureError.failed("Wait for the current scrolling capture operation.") }
        operating = true
        defer { operating = false }
        if let issue = await capacityIssue(stabilityPair: false) {
            addWarning(issue.localizedDescription)
            return ScrollAppendReport(disposition: .rejected, issue: issue)
        }
        try ensureAvailable()
        let frame = try await acquire(region)
        try ensureAvailable()
        let report = try await stitcher.append(frame)
        record(report)
        return report
    }

    func runAutomatic(onProgress: @escaping @MainActor (ScrollAppendReport, ScrollCaptureStatistics) -> Void) async throws {
        try ensureAvailable()
        guard started, !operating else { throw CaptureError.failed("Capture one manual frame before starting Auto.") }
        operating = true
        defer { operating = false }
        do {
            try await driver.begin(in: region)
            try ensureAvailable()
            try await runAutomaticLoop(onProgress: onProgress)
        } catch {
            if let warning = await driver.restore() { addWarning(warning) }
            throw error
        }
        if let warning = await driver.restore() { addWarning(warning) }
    }

    private func runAutomaticLoop(onProgress: @escaping @MainActor (ScrollAppendReport, ScrollCaptureStatistics) -> Void) async throws {
        while true {
            try ensureAvailable()
            if let issue = await capacityIssue(stabilityPair: true) {
                addWarning(issue.localizedDescription)
                onProgress(ScrollAppendReport(disposition: .rejected, issue: issue), await stitcher.statistics())
                return
            }
            try ensureAvailable()
            try await driver.scrollDown(points: nextScrollPoints)
            try await Task.sleep(for: timing.settlingDelay)
            try ensureAvailable()
            try await driver.validateTarget()
            try ensureAvailable()
            let first = try await acquire(region)
            try ensureAvailable()
            try await driver.validateTarget()
            try ensureAvailable()
            try await Task.sleep(for: timing.stabilityDelay)
            try ensureAvailable()
            try await driver.validateTarget()
            try ensureAvailable()
            let settled = try await acquire(region)
            try ensureAvailable()
            try await driver.validateTarget()
            try ensureAvailable()
            guard try await stitcher.framesAreStable(first, settled) else {
                driver.recordObservedMovement(points: nil)
                addWarning(ScrollCaptureIssue.dynamicContent.localizedDescription)
                onProgress(ScrollAppendReport(disposition: .rejected, issue: .dynamicContent), await stitcher.statistics())
                return
            }
            // A stable pixel overlap is insufficient if the native target was
            // replaced while acquisition or actor-isolated analysis suspended.
            try ensureAvailable()
            try await driver.validateTarget()
            try ensureAvailable()
            let report = try await stitcher.append(settled)
            let scale = CGFloat(settled.image.width) / region.rect.width
            switch report.disposition {
            case .appended:
                let observed = CGFloat(report.addedRows) / scale
                driver.recordObservedMovement(points: observed)
                // Keep a generous overlap for matching, but avoid making a
                // long page needlessly slow. The next request follows the
                // movement that was actually observed, not merely the wheel
                // delta that was requested.
                nextScrollPoints = max(48, min(region.rect.height * 0.68, observed * 1.08))
            case .unchanged:
                driver.recordObservedMovement(points: 0)
            case .rejected, .firstFrame:
                driver.recordObservedMovement(points: nil)
            }
            record(report)
            onProgress(report, await stitcher.statistics())
            switch report.disposition {
            case .appended:
                if driver.isAtEndOfContent() == true { return }
                continue
            case .unchanged:
                // A native scrollbar at its maximum is a clean completion. A
                // target without metrics stops conservatively with an explicit
                // ambiguity warning rather than claiming a complete document.
                if driver.isAtEndOfContent() == true { return }
                addWarning(ScrollCaptureIssue.ambiguousContent.localizedDescription)
                return
            case .rejected, .firstFrame:
                return
            }
        }
    }

    func finish() async throws -> ScrollCaptureResult {
        try ensureAvailable(allowStoppedAcquisition: true)
        guard started, !operating else { throw CaptureError.failed("Stop the active capture before finishing.") }
        operating = true
        defer { operating = false }
        let frame = try await stitcher.render()
        try ensureAvailable(allowStoppedAcquisition: true)
        return ScrollCaptureResult(image: frame.image, isComplete: warnings.isEmpty, warnings: warnings)
    }

    func statistics() async -> ScrollCaptureStatistics { await stitcher.statistics() }

    func invalidate() { invalidated = true }

    func preventFurtherAcquisition(reason: String) {
        // Separate from invalidation: already accepted pixels remain finishable.
        acquisitionStopReason = reason
        addWarning(reason)
    }

    func addWarning(_ warning: String) {
        if !warnings.contains(warning) { warnings.append(warning) }
    }

    private func ensureAvailable(allowStoppedAcquisition: Bool = false) throws {
        try Task.checkCancellation()
        if invalidated { throw CancellationError() }
        if !allowStoppedAcquisition, let acquisitionStopReason { throw CaptureError.failed(acquisitionStopReason) }
    }

    private func record(_ report: ScrollAppendReport) {
        if let issue = report.issue { addWarning(issue.localizedDescription) }
    }

    private func capacityIssue(stabilityPair: Bool) async -> ScrollCaptureIssue? {
        if await stitcher.canAcquireAnotherFrame(stabilityPair: stabilityPair) { return nil }
        let state = await stitcher.statistics()
        if state.frameCount >= limits.maximumFrames { return .frameLimit }
        if state.outputWidth * (state.outputHeight + 1) > limits.maximumOutputPixels { return .outputLimit }
        return .memoryLimit
    }
}
