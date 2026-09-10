import XCTest
import AppKit
import SwiftUI
@testable import SwiftShot

/// Exercises only a newly created test-owned diagnostics panel and its real
/// hosting view. No capture, input injection, preferences, or shared recorder.
/// The lead alone runs these native-host tests. No wall-clock latency gate.
@MainActor
final class DiagnosticsHostingLifecycleTests: XCTestCase {
    func testCaptureHidingDetachesAndReleasesHostUntilSafeReveal() async throws {
        let fixture = try makeFixture()
        defer { fixture.panel.close() }
        weak var oldHost = fixture.panel.contentView
        XCTAssertNotNil(oldHost)

        autoreleasepool {
            XCTAssertFalse(fixture.controller.setCaptureHidden(true))
            XCTAssertNil(fixture.panel.contentView,
                "A hidden diagnostics Form must not remain subscribed during capture")
            XCTAssertFalse(fixture.panel.isVisible)
            XCTAssertFalse(fixture.controller.setCaptureHidden(true))
            XCTAssertFalse(fixture.controller.show(avoiding: nil, captureHidden: true))
            XCTAssertNil(fixture.panel.contentView,
                "Requesting diagnostics while capture-hidden must not rebuild its host")
        }
        await drainQueuedTeardown()
        XCTAssertNil(oldHost, "Capture hiding retained the old hosting tree")
        XCTAssertEqual(ownedPanels(fixture).count, 1)

        XCTAssertTrue(fixture.controller.setCaptureHidden(false))
        fixture.panel.orderOut(nil)
        assertHostedModel(fixture.diagnostics, in: fixture.panel)
        XCTAssertEqual(ownedPanels(fixture).count, 1,
            "Reveal must reuse the existing panel, not create a duplicate window")
    }

    func testExplicitHideReleasesHostAndUnhidingCaptureDoesNotResurrectIt() async throws {
        let fixture = try makeFixture()
        defer { fixture.panel.close() }
        weak var oldHost = fixture.panel.contentView

        autoreleasepool {
            fixture.controller.hide()
            fixture.controller.hide()
            XCTAssertFalse(fixture.panel.isVisible)
            XCTAssertNil(fixture.panel.contentView)
            XCTAssertFalse(fixture.controller.setCaptureHidden(false))
            XCTAssertNil(fixture.panel.contentView,
                "Explicit hide clears visibility intent; capture completion must not rebuild")
        }
        await drainQueuedTeardown()
        XCTAssertNil(oldHost, "Explicit hide retained its observing hosting view")

        XCTAssertTrue(fixture.controller.show(avoiding: nil, captureHidden: false))
        fixture.panel.orderOut(nil)
        assertHostedModel(fixture.diagnostics, in: fixture.panel)
        XCTAssertEqual(ownedPanels(fixture).count, 1)
    }

    func testNoSafePlacementReleasesHostWithoutLosingVisibilityIntent() async throws {
        let fixture = try makeFixture()
        defer { fixture.panel.close() }
        weak var oldHost = fixture.panel.contentView
        // Covers every real display's visible rectangle, independently of the
        // production corner-candidate algorithm; there is no safe destination.
        let coversAllScreens = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        autoreleasepool {
            XCTAssertFalse(fixture.controller.show(avoiding: coversAllScreens, captureHidden: false))
            XCTAssertNil(fixture.panel.contentView,
                "A panel hidden for lack of safe placement must release its Form too")
            XCTAssertFalse(fixture.panel.isVisible)
            XCTAssertFalse(fixture.controller.setCaptureHidden(false))
            XCTAssertNil(fixture.panel.contentView)
        }
        await drainQueuedTeardown()
        XCTAssertNil(oldHost)

        XCTAssertTrue(fixture.controller.show(avoiding: nil, captureHidden: false))
        fixture.panel.orderOut(nil)
        assertHostedModel(fixture.diagnostics, in: fixture.panel)
        XCTAssertEqual(ownedPanels(fixture).count, 1)
    }

    func testHiddenRecordingExportsExactEventsAndRevealUsesSameCurrentModel() throws {
        let fixture = try makeFixture()
        defer { fixture.panel.close() }
        let diagnostics = fixture.diagnostics
        diagnostics.selection.workflow = .regionToPaste
        diagnostics.selection.context = .init(launch: .resident, desktop: .idle, displayCount: 1,
            interaction: .controlledHarness, content: .raw)
        diagnostics.setEnabled(true)
        let id = try XCTUnwrap(diagnostics.beginRun())
        XCTAssertFalse(fixture.controller.setCaptureHidden(true))
        XCTAssertNil(fixture.panel.contentView)

        // Literal fake-clock times establish recorder semantics, not performance.
        let stages: [WorkflowPerformance.Stage] = [.captureRequested, .selectorReady,
            .selectionCommitted, .editorReady, .copyRequested, .clipboardReady]
        for (index, stage) in stages.enumerated() {
            fixture.clock.now = UInt64(index + 1) * 10_000_000
            XCTAssertTrue(diagnostics.mark(stage, for: id))
        }
        XCTAssertTrue(diagnostics.updatePixels(input: .init(width: 3840, height: 2160),
            output: .init(width: 1920, height: 1080), for: id))
        XCTAssertTrue(diagnostics.action(for: id))
        XCTAssertTrue(diagnostics.action(correction: true, for: id))
        let unfinished = try JSONDecoder().decode(WorkflowPerformance.Report.self, from: diagnostics.exportData())
        XCTAssertEqual(unfinished.activeRuns, 1)
        XCTAssertTrue(unfinished.runs.isEmpty)
        XCTAssertEqual(unfinished.captureLatencyTrace?.activeRunID, id)
        XCTAssertEqual(diagnostics.activeRunID, id)
        XCTAssertEqual(diagnostics.activeStages, stages)
        XCTAssertFalse(diagnostics.activeStages.contains(.pasteVerified))

        XCTAssertTrue(fixture.controller.setCaptureHidden(false))
        fixture.panel.orderOut(nil)
        assertHostedModel(diagnostics, in: fixture.panel)
        weak var revealedHost = fixture.panel.contentView
        XCTAssertTrue(fixture.controller.show(avoiding: nil, captureHidden: false))
        fixture.panel.orderOut(nil)
        XCTAssertTrue(fixture.panel.contentView === revealedHost,
            "Repeated visible show should reuse the current host")
        XCTAssertEqual(ownedPanels(fixture).count, 1)
        XCTAssertEqual(diagnostics.activeStages, stages, "Reveal must not add presentation or paste events")
        XCTAssertEqual(diagnostics.activeContext?.inputPixels, .init(width: 3840, height: 2160))
        XCTAssertEqual(diagnostics.activeContext?.outputPixels, .init(width: 1920, height: 1080))
        XCTAssertEqual(diagnostics.observedActions, 2)
        XCTAssertEqual(diagnostics.observedCorrections, 1)

        fixture.clock.now = 70_000_000
        XCTAssertTrue(diagnostics.finish(outcome: .success, for: id))
        let exported = try JSONDecoder().decode(WorkflowPerformance.Report.self, from: diagnostics.exportData())
        let run = try XCTUnwrap(exported.runs.first)
        XCTAssertEqual(exported.activeRuns, 0)
        XCTAssertEqual(exported.runs.count, 1)
        XCTAssertEqual(run.id, id)
        XCTAssertEqual(run.events.map(\.stage), stages)
        XCTAssertEqual(run.events.map(\.offsetMilliseconds), [10, 20, 30, 40, 50, 60])
        XCTAssertEqual(run.context.inputPixels, .init(width: 3840, height: 2160))
        XCTAssertEqual(run.context.outputPixels, .init(width: 1920, height: 1080))
        XCTAssertEqual(run.actions, 2)
        XCTAssertEqual(run.corrections, 1)
        XCTAssertFalse(run.measurements.contains { $0.span == .regionToPaste },
            "Host recreation must not invent the missing explicit paste verification")
    }

    func testUserCloseWhileCaptureHiddenStaysDismissedAndKeepsRunActive() async throws {
        let fixture = try makeFixture()
        defer { fixture.panel.close() }
        fixture.diagnostics.setEnabled(true)
        let id = try XCTUnwrap(fixture.diagnostics.beginRun())
        weak var oldHost = fixture.panel.contentView
        autoreleasepool {
            XCTAssertFalse(fixture.controller.setCaptureHidden(true))
            fixture.panel.close()
        }
        await drainQueuedTeardown()
        XCTAssertNil(oldHost)
        XCTAssertFalse(fixture.controller.setCaptureHidden(false))
        XCTAssertFalse(fixture.panel.isVisible)
        XCTAssertNil(fixture.panel.contentView)
        XCTAssertEqual(fixture.diagnostics.activeRunID, id,
            "Closing diagnostics is not canceling the active recorder")
        XCTAssertTrue(fixture.diagnostics.mark(.captureRequested, for: id))
        let report = try JSONDecoder().decode(WorkflowPerformance.Report.self, from: fixture.diagnostics.exportData())
        XCTAssertEqual(report.activeRuns, 1)
        XCTAssertTrue(report.runs.isEmpty)
        XCTAssertFalse(ownedPanels(fixture).contains { $0 !== fixture.panel },
            "Capture completion resurrected a user-dismissed diagnostics window")
    }

    private final class Clock { var now: UInt64 = 0 }
    private struct Fixture {
        let controller: PerformanceDiagnosticsWindowController
        let diagnostics: PerformanceDiagnostics
        let panel: DiagnosticsPanel
        let existingWindows: Set<ObjectIdentifier>
        let clock: Clock
    }

    private func makeFixture() throws -> Fixture {
        guard NSScreen.screens.contains(where: { $0.visibleFrame.width >= 324 && $0.visibleFrame.height >= 384 }) else {
            throw XCTSkip("A native screen with room for the test-owned diagnostics panel is required")
        }
        let clock = Clock()
        let recorder = WorkflowPerformance(now: { clock.now }, resources: {
            WorkflowResourceSample(cpuNanoseconds: 0, residentBytes: 1024, peakResidentBytes: 1024)
        })
        let diagnostics = PerformanceDiagnostics(recorder: recorder, latencyTrace: CaptureLatencyTrace())
        let controller = PerformanceDiagnosticsWindowController(diagnostics: diagnostics)
        let existing = Set(NSApp.windows.map { ObjectIdentifier($0) })
        let panel: DiagnosticsPanel = try autoreleasepool {
            XCTAssertTrue(controller.show(avoiding: nil, captureHidden: false))
            let matches = NSApp.windows.compactMap { window -> DiagnosticsPanel? in
                guard !existing.contains(ObjectIdentifier(window)), let panel = window as? DiagnosticsPanel,
                      let host = panel.contentView as? NSHostingView<PerformanceDiagnosticsView>,
                      host.rootView.diagnostics === diagnostics else { return nil }
                return panel
            }
            XCTAssertEqual(matches.count, 1)
            let panel = try XCTUnwrap(matches.first)
            panel.orderOut(nil)
            return panel
        }
        return Fixture(controller: controller, diagnostics: diagnostics, panel: panel,
            existingWindows: existing, clock: clock)
    }

    private func ownedPanels(_ fixture: Fixture) -> [DiagnosticsPanel] {
        NSApp.windows.compactMap { window in
            guard !fixture.existingWindows.contains(ObjectIdentifier(window)) else { return nil }
            return window as? DiagnosticsPanel
        }
    }

    private func assertHostedModel(_ expected: PerformanceDiagnostics, in panel: NSWindow,
                                   file: StaticString = #filePath, line: UInt = #line) {
        autoreleasepool {
            guard let host = panel.contentView as? NSHostingView<PerformanceDiagnosticsView> else {
                XCTFail("Visible diagnostics did not rebuild its real hosted Form", file: file, line: line)
                return
            }
            XCTAssertTrue(host.rootView.diagnostics === expected,
                "Recreated content must use the original active model", file: file, line: line)
        }
    }

    private func drainQueuedTeardown() async {
        // Drain pending AppKit/SwiftUI releases, without a millisecond timeout or
        // an assertion about how fast the machine presents or destroys a view.
        for _ in 0..<2 {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }
}
