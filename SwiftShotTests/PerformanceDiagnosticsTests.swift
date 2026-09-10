import XCTest
import CoreGraphics
import AppKit
@testable import SwiftShot

@MainActor
final class PerformanceDiagnosticsTests: XCTestCase {
    func testLatencyTraceArmsAndDisarmsWithDiagnosticLifecycle() throws {
        let trace = CaptureLatencyTrace()
        let diagnostics = PerformanceDiagnostics(recorder: WorkflowPerformance(), latencyTrace: trace)
        XCTAssertNil(diagnostics.beginRun())
        XCTAssertNil(trace.activeRunID)
        diagnostics.setEnabled(true)
        let old = try XCTUnwrap(diagnostics.beginRun())
        XCTAssertEqual(trace.activeRunID, old)
        XCTAssertTrue(trace.mark(.captureRequested, for: old))
        XCTAssertFalse(diagnostics.clearResults())
        diagnostics.setEnabled(false)
        XCTAssertNil(trace.activeRunID)
        XCTAssertFalse(trace.mark(.receiptDelivered, for: old))
        XCTAssertEqual(trace.snapshot().runs.first?.events.count, 1)
        XCTAssertTrue(trace.snapshot().runs.first?.isComplete == true)
        diagnostics.setEnabled(true)
        let next = try XCTUnwrap(diagnostics.beginRun())
        XCTAssertFalse(trace.mark(.transactionCompleted, for: old))
        XCTAssertTrue(diagnostics.finish(outcome: .success, for: next))
        XCTAssertNil(trace.activeRunID)
        XCTAssertTrue(diagnostics.clearResults())
        XCTAssertTrue(trace.snapshot().runs.isEmpty)
    }

    func testLatencyTraceExportsSameSnapshotWithoutManufacturingReadiness() throws {
        let trace = CaptureLatencyTrace()
        let diagnostics = PerformanceDiagnostics(recorder: WorkflowPerformance(), latencyTrace: trace)
        diagnostics.setEnabled(true)
        let id = try XCTUnwrap(diagnostics.beginRun())
        XCTAssertTrue(trace.mark(.layoutFinished, for: id, presentation: .selector, surface: 0))
        let data = try diagnostics.exportData()
        let report = try JSONDecoder().decode(WorkflowPerformance.Report.self, from: data)
        let exported = try XCTUnwrap(report.captureLatencyTrace)
        XCTAssertEqual(exported.activeRunID, id)
        XCTAssertEqual(exported.runs.first?.events.map(\.stage), [.layoutFinished])
        XCTAssertFalse(exported.runs.first?.isComplete ?? true)
        XCTAssertTrue(report.runs.isEmpty)
        XCTAssertFalse(diagnostics.activeStages.contains(.selectorReady))
        XCTAssertTrue(diagnostics.finish(outcome: .success, for: id))
        let finished = diagnostics.snapshot()
        XCTAssertNil(finished.captureLatencyTrace?.activeRunID)
        XCTAssertTrue(finished.captureLatencyTrace?.runs.first?.isComplete == true)
        XCTAssertTrue(finished.runs.first?.measurements.isEmpty == true)
    }

    func testDiagnosticsPanelDisablesOrderOutAnimationBeforePresentation() {
        let panel = PerformanceDiagnosticsWindowController.makeDiagnosticsPanel()
        defer { panel.close() }
        XCTAssertFalse(panel.isVisible, "Constructing diagnostics must not present UI")
        XCTAssertEqual(panel.animationBehavior, NSWindow.AnimationBehavior.none,
            "Capture hiding must not leave the diagnostics utility panel fading onscreen")
    }

    func testDiagnosticsSavePanelDisablesOrderOutAnimationBeforePresentation() {
        let panel = PerformanceDiagnosticsWindowController.makeSavePanel()
        defer { panel.close() }
        XCTAssertFalse(panel.isVisible, "Constructing the metadata chooser must not present UI")
        XCTAssertEqual(panel.animationBehavior, NSWindow.AnimationBehavior.none,
            "Capture hiding must not leave the diagnostics save panel fading onscreen")
    }

    private final class Clock {
        var now: UInt64 = 0
        var samples = 0
        func resources() -> WorkflowResourceSample {
            samples += 1
            return .init(cpuNanoseconds: now / 10, residentBytes: 1000, peakResidentBytes: 2000)
        }
    }
    private func make(_ clock: Clock) -> PerformanceDiagnostics {
        PerformanceDiagnostics(recorder: WorkflowPerformance(now: { clock.now }, resources: { clock.resources() }))
    }

    func testDisabledDiagnosticsNeverStartOrSampleFromProductionHooks() {
        let clock = Clock()
        let instrumented = make(clock)
        XCTAssertFalse(instrumented.isEnabled)
        XCTAssertNil(instrumented.beginRun())
        XCTAssertFalse(instrumented.mark(.captureRequested))
        XCTAssertFalse(instrumented.action(correction: true))
        XCTAssertFalse(instrumented.finish(outcome: .success))
        XCTAssertNil(instrumented.activeRunID)
        XCTAssertTrue(instrumented.snapshot().runs.isEmpty)
        XCTAssertEqual(clock.samples, 0)
    }

    func testPasteRequiresExplicitVerificationAndConditionsRemainFrozen() throws {
        let clock = Clock()
        let subject = make(clock)
        subject.selection.workflow = .regionToPaste
        subject.selection.context = .init(launch: .resident, desktop: .idle, displayCount: 1,
                                         interaction: .human, content: .ordinaryEdited)
        subject.setEnabled(true)
        let id = try XCTUnwrap(subject.beginRun())
        XCTAssertNil(subject.beginRun(), "A second begin must not drop or replace the active sample")
        subject.selection.context.launch = .cold
        clock.now = 10_000_000
        XCTAssertTrue(subject.mark(.captureRequested, for: id))
        clock.now = 20_000_000
        XCTAssertTrue(subject.mark(.clipboardReady, for: id))
        XCTAssertFalse(subject.mark(.pasteVerified, for: id), "Automatic hooks must not invent paste")
        XCTAssertFalse(subject.activeStages.contains(.pasteVerified))
        clock.now = 40_000_000
        XCTAssertTrue(subject.verifyPaste())
        XCTAssertFalse(subject.verifyPaste(), "Repeat clicks must preserve the first observation")
        XCTAssertTrue(subject.finish(outcome: .success, for: id))
        let run = try XCTUnwrap(subject.snapshot().runs.first)
        XCTAssertEqual(run.context.launch, .resident)
        XCTAssertEqual(run.measurements.first { $0.span == .regionToPaste }?.milliseconds, 30)
        XCTAssertNil(run.actions, "Unobserved actions must not become zero")
        XCTAssertEqual(clock.samples, 2)
    }

    func testStaleCallbacksCannotMarkFinishOrChangeDimensionsOfNewRun() throws {
        let subject = make(Clock())
        subject.setEnabled(true)
        let stale = try XCTUnwrap(subject.beginRun())
        XCTAssertTrue(subject.finish(outcome: .canceled, for: stale))
        let current = try XCTUnwrap(subject.beginRun())
        XCTAssertFalse(subject.mark(.copyRequested, for: nil), "A captured nil ID must not attach an older disabled operation to a new run")
        XCTAssertFalse(subject.finish(outcome: .success, for: nil))
        XCTAssertFalse(subject.mark(.clipboardReady, for: stale))
        XCTAssertFalse(subject.action(correction: true, for: stale))
        XCTAssertFalse(subject.finish(outcome: .success, for: stale))
        XCTAssertFalse(subject.updatePixels(input: .init(width: 80, height: 40), for: stale))
        XCTAssertTrue(subject.updatePixels(input: .init(width: 3840, height: 2160),
                                           output: .init(width: 1920, height: 1080), for: current))
        XCTAssertFalse(subject.updatePixels(output: .init(width: -1, height: 40), for: current))
        XCTAssertTrue(subject.action(for: current))
        XCTAssertTrue(subject.action(correction: true, for: current))
        XCTAssertTrue(subject.finish(outcome: .success, for: current))
        let run = try XCTUnwrap(subject.snapshot().runs.last)
        XCTAssertTrue(run.events.isEmpty)
        XCTAssertEqual(run.context.inputPixels, .init(width: 3840, height: 2160))
        XCTAssertEqual(run.context.outputPixels, .init(width: 1920, height: 1080))
        XCTAssertEqual(run.actions, 2)
        XCTAssertEqual(run.corrections, 1)
    }

    func testDisablingCancelsOnceAndStopsSamplingWithoutDiscardingEvidence() throws {
        let clock = Clock()
        let diagnostics = make(clock)
        diagnostics.setEnabled(true)
        _ = try XCTUnwrap(diagnostics.beginRun())
        diagnostics.setEnabled(false)
        diagnostics.setEnabled(false)
        XCTAssertFalse(diagnostics.mark(.clipboardReady))
        XCTAssertFalse(diagnostics.verifyPaste())
        XCTAssertEqual(diagnostics.snapshot().runs.map(\.outcome), [.canceled])
        XCTAssertNil(diagnostics.activeRunID)
        XCTAssertEqual(clock.samples, 2)
    }

    func testExportRetainsIncompleteEvidenceAndContainsNoContentOrPathFields() throws {
        let diagnostics = make(Clock())
        diagnostics.setEnabled(true)
        _ = try XCTUnwrap(diagnostics.beginRun())
        XCTAssertTrue(diagnostics.mark(.captureRequested))
        XCTAssertTrue(diagnostics.mark(.clipboardReady))
        XCTAssertTrue(diagnostics.finish(outcome: .success))
        let data = try diagnostics.exportData()
        let report = try JSONDecoder().decode(WorkflowPerformance.Report.self, from: data)
        let run = try XCTUnwrap(report.runs.first)
        XCTAssertEqual(run.outcome, .success)
        XCTAssertFalse(run.events.contains { $0.stage == .pasteVerified })
        XCTAssertFalse(run.measurements.contains { $0.span == .regionToPaste })
        XCTAssertTrue(report.summaries.contains { $0.span == .regionToPaste && $0.successfulRunsMissingSpan == 1 })
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let runs = try XCTUnwrap(object["runs"] as? [[String: Any]])
        for forbidden in ["image", "png", "text", "path", "url", "windowTitle", "documentID", "request"] {
            XCTAssertNil(runs[0][forbidden])
        }
    }

    func testDiagnosticsPlacementAvoidsCaptureAndRefusesNoSafeVisibleSpace() throws {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let target = CGRect(x: 800, y: 0, width: 640, height: 900)
        let frame = try XCTUnwrap(DiagnosticsWindowPlacement.frame(visibleFrames: [screen], avoiding: target))
        XCTAssertTrue(screen.contains(frame))
        XCTAssertFalse(frame.intersects(target))
        XCTAssertNil(DiagnosticsWindowPlacement.frame(visibleFrames: [screen], avoiding: screen))
        XCTAssertNil(DiagnosticsWindowPlacement.frame(visibleFrames: [CGRect(x: 0, y: 0, width: 200, height: 200)], avoiding: nil))
    }
}
