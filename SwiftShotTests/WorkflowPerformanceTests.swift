import XCTest
@testable import SwiftShot

@MainActor
final class WorkflowPerformanceTests: XCTestCase {
    private final class Clock {
        var now: UInt64 = 0
        var sample = WorkflowResourceSample(cpuNanoseconds: 0, residentBytes: 10_000, peakResidentBytes: 12_000)
    }

    func testRecordsNamedSpansActionsCorrectionsAndProcessResourceDeltas() {
        let clock = Clock()
        let performance = WorkflowPerformance(now: { clock.now }, resources: { clock.sample })
        let id = performance.begin(workflow: .regionToPaste)
        performance.mark(.captureRequested, for: id)
        clock.now = 100_000_000
        performance.mark(.selectorReady, for: id)
        clock.now = 120_000_000
        performance.mark(.selectionCommitted, for: id)
        clock.now = 150_000_000
        performance.mark(.editorReady, for: id)
        clock.now = 200_000_000
        performance.mark(.copyRequested, for: id)
        clock.now = 250_000_000
        performance.mark(.clipboardReady, for: id)
        clock.now = 300_000_000
        performance.mark(.pasteVerified, for: id)
        performance.action(for: id)
        performance.action(for: id, correction: true)
        clock.sample = WorkflowResourceSample(cpuNanoseconds: 20_000_000, residentBytes: 15_000, peakResidentBytes: 18_000)
        performance.finish(id, outcome: .success)
        let run = performance.snapshot().runs[0]
        XCTAssertEqual(run.measurements.first(where: { $0.span == .shortcutToSelector })?.milliseconds, 100)
        XCTAssertEqual(run.measurements.first(where: { $0.span == .selectionToEditor })?.milliseconds, 30)
        XCTAssertEqual(run.measurements.first(where: { $0.span == .copyToClipboard })?.milliseconds, 50)
        XCTAssertEqual(run.measurements.first(where: { $0.span == .regionToPaste })?.milliseconds, 300)
        XCTAssertEqual(run.actions, 2)
        XCTAssertEqual(run.corrections, 1)
        XCTAssertEqual(run.cpuMilliseconds, 20)
        XCTAssertEqual(run.residentStartBytes, 10_000)
        XCTAssertEqual(run.residentEndBytes, 15_000)
        XCTAssertEqual(run.peakResidentBytes, 18_000)
    }

    func testMedianAndP95ExcludeFailedAndCanceledRunsWithoutHidingCounts() {
        let clock = Clock()
        let performance = WorkflowPerformance(now: { clock.now }, resources: { clock.sample })
        for (duration, outcome) in [(10, WorkflowPerformance.Outcome.success), (20, .success), (30, .success), (40, .success), (1000, .failed), (2000, .canceled)] {
            let id = performance.begin(workflow: .regionToPaste,
                context: .init(launch: .resident, desktop: .idle, displayCount: 1,
                               inputPixels: .init(width: 3840, height: 2160), outputPixels: .init(width: 3840, height: 2160),
                               interaction: .automatedUI, content: .ordinaryEdited))
            performance.mark(.copyRequested, for: id)
            clock.now += UInt64(duration) * 1_000_000
            performance.mark(.clipboardReady, for: id)
            performance.finish(id, outcome: outcome)
        }
        let snapshot = performance.snapshot()
        let summary = snapshot.summaries.first { $0.span == .copyToClipboard }!
        XCTAssertEqual(summary.sampleCount, 4)
        XCTAssertEqual(summary.medianMilliseconds, 25)
        XCTAssertEqual(summary.p95Milliseconds, 40)
        XCTAssertEqual(summary.successfulRunsMissingSpan, 0)
        XCTAssertEqual(summary.failedRuns, 1)
        XCTAssertEqual(summary.canceledRuns, 1)
        XCTAssertEqual(summary.gate, .incompleteEvidence)
        XCTAssertEqual(snapshot.runs.count, 6)
    }

    func testIncompleteOrReversedStagesAreNotInventedAsSuccessfulMeasurements() {
        let clock = Clock()
        let performance = WorkflowPerformance(now: { clock.now }, resources: { clock.sample })
        let id = performance.begin(workflow: .regionToPaste)
        performance.mark(.clipboardReady, for: id)
        clock.now = 10_000_000
        performance.mark(.copyRequested, for: id)
        performance.finish(id, outcome: .success)
        let run = performance.snapshot().runs[0]
        XCTAssertNil(run.measurements.first { $0.span == .copyToClipboard })
        XCTAssertNil(run.measurements.first { $0.span == .regionToPaste })
        XCTAssertNil(run.actions)
        XCTAssertNil(run.corrections)
        let summary = performance.snapshot().summaries.first { $0.span == .copyToClipboard }!
        XCTAssertEqual(summary.successfulRunsMissingSpan, 1)
    }

    func testBoundedRunsAndActiveSessionsCountDroppedEvidence() {
        let performance = WorkflowPerformance(capacity: 2, activeCapacity: 1)
        let dropped = performance.begin(workflow: .ocr)
        let kept = performance.begin(workflow: .ocr)
        XCTAssertFalse(performance.mark(.ocrComplete, for: dropped))
        performance.finish(kept, outcome: .success)
        for _ in 0..<2 { performance.finish(performance.begin(workflow: .ocr), outcome: .success) }
        XCTAssertEqual(performance.snapshot().runs.count, 2)
        XCTAssertEqual(performance.snapshot().droppedRuns, 1)
        XCTAssertEqual(performance.snapshot().droppedActiveRuns, 1)
    }

    func testDuplicateReadinessMarkPreservesFirstCompletionAndNoActiveMarkDoesNothing() {
        let clock = Clock()
        let performance = WorkflowPerformance(now: { clock.now }, resources: { clock.sample })
        XCTAssertFalse(performance.mark(.editorReady))
        let id = performance.begin(workflow: .regionToPaste)
        performance.mark(.copyRequested)
        clock.now = 10_000_000
        XCTAssertTrue(performance.mark(.clipboardReady))
        clock.now = 100_000_000
        XCTAssertFalse(performance.mark(.clipboardReady))
        performance.finish(id, outcome: .success)
        XCTAssertEqual(performance.snapshot().runs[0].measurements.first { $0.span == .copyToClipboard }?.milliseconds, 10)
    }

    func testReportGroupsConditionsInsteadOfMixingColdBusyAndMultidisplaySamples() throws {
        let performance = WorkflowPerformance()
        let cold = WorkflowPerformance.Context(launch: .cold, desktop: .idle, displayCount: 1)
        let busy = WorkflowPerformance.Context(launch: .resident, desktop: .busy, displayCount: 2)
        performance.finish(performance.begin(workflow: .ocr, context: cold), outcome: .success)
        performance.finish(performance.begin(workflow: .ocr, context: busy), outcome: .success)
        XCTAssertEqual(Set(performance.snapshot().summaries.map(\.context)).count, 2)
        let data = try JSONEncoder().encode(performance.snapshot())
        let decoded = try JSONDecoder().decode(WorkflowPerformance.Report.self, from: data)
        XCTAssertEqual(decoded.runs.count, 2)
        XCTAssertEqual(decoded.schemaVersion, 1)
    }
}
