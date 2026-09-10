import Foundation
import Observation
import CoreGraphics

/// Explicit, session-local instrumentation. Constructing or showing this model
/// does not begin a run, sample resources, poll, capture pixels, or persist data.
@Observable @MainActor
final class PerformanceDiagnostics {
    static let shared = PerformanceDiagnostics(recorder: WorkflowPerformance(activeCapacity: 1), latencyTrace: .shared)

    struct Selection {
        var workflow: WorkflowPerformance.Workflow = .regionToPaste
        var context = WorkflowPerformance.Context()
    }
    var selection = Selection()
    private(set) var isEnabled = false
    private(set) var activeRunID: UUID?
    private(set) var activeStages: [WorkflowPerformance.Stage] = []
    private(set) var activeContext: WorkflowPerformance.Context?
    private(set) var activeWorkflow: WorkflowPerformance.Workflow?
    private(set) var observedActions: Int?
    private(set) var observedCorrections: Int?
    private(set) var completedCount = 0
    private(set) var failedCount = 0
    private(set) var canceledCount = 0
    private(set) var droppedCount = 0
    private(set) var lastMissingStages: [WorkflowPerformance.Stage] = []
    private(set) var lastMessage = "Diagnostics are off. No measurements are being collected."
    private(set) var isWindowVisible = false
    private(set) var isCaptureHidden = false
    private(set) var isExporting = false
    @ObservationIgnored private let recorder: WorkflowPerformance
    @ObservationIgnored private let latencyTrace: CaptureLatencyTrace
    @ObservationIgnored private var windowController: PerformanceDiagnosticsWindowController?

    init(recorder: WorkflowPerformance, latencyTrace: CaptureLatencyTrace = CaptureLatencyTrace()) {
        self.recorder = recorder
        self.latencyTrace = latencyTrace
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        if !enabled, let id = activeRunID { finish(outcome: .canceled, for: id) }
        isEnabled = enabled
        lastMessage = enabled ? "Ready. Choose conditions, then Begin Run." : "Diagnostics are off. Retained metadata remain in memory until cleared or quit."
    }

    @discardableResult func beginRun() -> UUID? {
        guard isEnabled, activeRunID == nil else { return nil }
        let context = selection.context
        guard context.displayCount.map({ (1...16).contains($0) }) ?? true,
              Self.valid(context.inputPixels), Self.valid(context.outputPixels) else {
            lastMessage = "Choose valid display counts and positive image dimensions before beginning."
            return nil
        }
        activeContext = context
        activeWorkflow = selection.workflow
        activeStages = []
        observedActions = nil
        observedCorrections = nil
        let id = recorder.begin(workflow: selection.workflow, context: context)
        activeRunID = id
        latencyTrace.beginRun(id)
        lastMessage = "Run armed. Perform the selected workflow; Begin Run is not a capture timestamp."
        return id
    }

    /// Synchronous convenience only. Async integrations must carry the captured
    /// optional UUID into the explicit `for:` overload; explicit nil is a no-op.
    @discardableResult func mark(_ stage: WorkflowPerformance.Stage) -> Bool { mark(stage, for: activeRunID) }
    @discardableResult func mark(_ stage: WorkflowPerformance.Stage, for id: UUID?) -> Bool {
        guard stage != .pasteVerified, matchesActive(id), let id, recorder.mark(stage, for: id) else { return false }
        activeStages.append(stage)
        return true
    }

    /// User observation only: records the verification-button timestamp, not a
    /// guessed earlier paste event or a physical-display presentation timestamp.
    @discardableResult func verifyPaste() -> Bool {
        guard matchesActive(activeRunID), let id = activeRunID, recorder.mark(.pasteVerified, for: id) else { return false }
        activeStages.append(.pasteVerified)
        lastMessage = "Paste explicitly verified. This timestamp includes the delay before pressing Verify."
        return true
    }

    @discardableResult func action(correction: Bool = false) -> Bool { action(correction: correction, for: activeRunID) }
    @discardableResult func action(correction: Bool = false, for id: UUID?) -> Bool {
        guard matchesActive(id), let id else { return false }
        recorder.action(for: id, correction: correction)
        observedActions = min(1_000_000, (observedActions ?? 0) + 1)
        observedCorrections = min(1_000_000, (observedCorrections ?? 0) + (correction ? 1 : 0))
        return true
    }

    @discardableResult func updatePixels(input: WorkflowPerformance.PixelSize? = nil,
                                         output: WorkflowPerformance.PixelSize? = nil) -> Bool {
        updatePixels(input: input, output: output, for: activeRunID)
    }
    @discardableResult func updatePixels(input: WorkflowPerformance.PixelSize? = nil,
                                         output: WorkflowPerformance.PixelSize? = nil, for id: UUID?) -> Bool {
        guard matchesActive(id), let id, var context = activeContext,
              input != nil || output != nil, Self.valid(input), Self.valid(output) else { return false }
        if let input { context.inputPixels = input }
        if let output { context.outputPixels = output }
        activeContext = context
        recorder.update(context: context, for: id)
        return true
    }

    @discardableResult func finish(outcome: WorkflowPerformance.Outcome) -> Bool { finish(outcome: outcome, for: activeRunID) }
    @discardableResult func finish(outcome: WorkflowPerformance.Outcome, for id: UUID?) -> Bool {
        guard matchesActive(id), let id else { return false }
        lastMissingStages = missingStages
        recorder.finish(id, outcome: outcome)
        latencyTrace.endRun(id)
        activeRunID = nil
        activeContext = nil
        activeWorkflow = nil
        activeStages = []
        observedActions = nil
        observedCorrections = nil
        refreshCounts()
        lastMessage = lastMissingStages.isEmpty ? "Run recorded as \(outcome.rawValue). This does not establish physical-display or full-goal acceptance." :
            "Run recorded as \(outcome.rawValue) with \(lastMissingStages.count) missing stage(s). Missing evidence was not filled in."
        return true
    }

    var missingStages: [WorkflowPerformance.Stage] {
        guard let workflow = activeWorkflow else { return [] }
        let required = Set(WorkflowPerformance.Span.allCases.filter { $0.applies(to: workflow) }.flatMap { [$0.endpoints.0, $0.endpoints.1] })
        return WorkflowPerformance.Stage.allCases.filter { required.contains($0) && !activeStages.contains($0) }
    }

    func snapshot() -> WorkflowPerformance.Report {
        var report = recorder.snapshot()
        report.captureLatencyTrace = latencyTrace.snapshot()
        return report
    }
    func exportData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(snapshot())
    }

    @discardableResult func clearResults() -> Bool {
        guard activeRunID == nil else { return false }
        recorder.reset()
        latencyTrace.reset()
        refreshCounts()
        lastMissingStages = []
        lastMessage = "Retained diagnostic metadata cleared. Nothing was deleted from disk."
        return true
    }

    @discardableResult func showWindow(avoiding captureFrame: CGRect? = nil) -> Bool {
        if windowController == nil { windowController = PerformanceDiagnosticsWindowController(diagnostics: self) }
        isWindowVisible = windowController?.show(avoiding: captureFrame, captureHidden: isCaptureHidden) ?? false
        if !isWindowVisible { lastMessage = "Diagnostics are hidden because capture is active or no safe display space is available." }
        return isWindowVisible
    }
    func hideWindow() { windowController?.hide(); isWindowVisible = false }
    func setCaptureHidden(_ hidden: Bool) {
        isCaptureHidden = hidden
        isWindowVisible = windowController?.setCaptureHidden(hidden) ?? false
    }
    func exportWithSavePanel() {
        guard !isExporting, !isCaptureHidden else { return }
        if windowController == nil { windowController = PerformanceDiagnosticsWindowController(diagnostics: self) }
        do {
            let data = try exportData()
            isExporting = true
            windowController?.export(data: data) { [weak self] result in
                guard let self else { return }
                self.isExporting = false
                switch result {
                case .success(let wrote): self.lastMessage = wrote ? "Diagnostic JSON exported. Active runs, if any, remain explicitly unfinished." : "Diagnostic export canceled."
                case .failure: self.lastMessage = "Diagnostic export failed. No completed run was removed; choose another destination and retry."
                }
            }
        } catch { lastMessage = "Diagnostic JSON could not be encoded. Retained samples remain available." }
    }

    func diagnosticsWindowDidClose() { isWindowVisible = false }

    private func matchesActive(_ id: UUID?) -> Bool { isEnabled && id != nil && id == activeRunID }
    private static func valid(_ size: WorkflowPerformance.PixelSize?) -> Bool {
        guard let size else { return true }
        return (1...131_072).contains(size.width) && (1...131_072).contains(size.height) &&
            size.width * size.height <= 1_000_000_000
    }
    private func refreshCounts() {
        let report = recorder.snapshot()
        completedCount = report.runs.count
        failedCount = report.runs.filter { $0.outcome == .failed }.count
        canceledCount = report.runs.filter { $0.outcome == .canceled }.count
        droppedCount = report.droppedRuns + report.droppedActiveRuns
    }
}

enum DiagnosticsWindowPlacement {
    static func frame(visibleFrames: [CGRect], avoiding: CGRect?) -> CGRect? {
        if let avoiding, !finite(avoiding) { return nil }
        for visible in visibleFrames where finite(visible) && visible.width >= 324 && visible.height >= 384 {
            let size = CGSize(width: min(400, visible.width - 24), height: min(660, visible.height - 24))
            let candidates = [
                CGRect(x: visible.maxX - size.width - 12, y: visible.maxY - size.height - 12, width: size.width, height: size.height),
                CGRect(x: visible.minX + 12, y: visible.maxY - size.height - 12, width: size.width, height: size.height),
                CGRect(x: visible.maxX - size.width - 12, y: visible.minY + 12, width: size.width, height: size.height),
                CGRect(x: visible.minX + 12, y: visible.minY + 12, width: size.width, height: size.height)
            ]
            if let frame = candidates.first(where: { visible.contains($0) && !(avoiding?.insetBy(dx: -12, dy: -12).intersects($0) ?? false) }) { return frame }
        }
        return nil
    }
    private static func finite(_ rect: CGRect) -> Bool {
        [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite) && rect.width > 0 && rect.height > 0
    }
}
