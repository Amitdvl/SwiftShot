import Foundation
import Darwin

/// Process-wide snapshots, not per-workflow attribution. No polling or timers.
struct WorkflowResourceSample: Codable, Sendable {
    var cpuNanoseconds: UInt64?
    var residentBytes: UInt64?
    var peakResidentBytes: UInt64?

    static func capture() -> Self {
        var usage = rusage()
        let usageOK = getrusage(RUSAGE_SELF, &usage) == 0
        func nanoseconds(_ value: timeval) -> UInt64 {
            UInt64(max(0, value.tv_sec)) * 1_000_000_000 + UInt64(max(0, value.tv_usec)) * 1_000
        }
        var info = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return Self(cpuNanoseconds: usageOK ? nanoseconds(usage.ru_utime) + nanoseconds(usage.ru_stime) : nil,
                    residentBytes: result == KERN_SUCCESS ? info.resident_size : nil,
                    peakResidentBytes: usageOK ? UInt64(max(0, usage.ru_maxrss)) : nil)
    }
}

/// Bounded metadata-only diagnostics. Mark calls only read a monotonic clock;
/// process CPU/RSS are sampled at begin/end. Nothing is persisted automatically.
@MainActor
final class WorkflowPerformance {
    static let shared = WorkflowPerformance()

    enum Workflow: String, Codable, CaseIterable, Sendable {
        case regionToPaste, windowArrowToPaste, redactToSave, ocr, historyReuse
        case regionCapture, windowCapture, fullscreenCapture, quickCopy, scrollCapture, idleObservation
    }
    enum Stage: String, Codable, CaseIterable, Sendable {
        case captureRequested, selectorReady, selectionCommitted, editorReady
        case copyRequested, clipboardReady, pasteVerified, saveRequested, saveComplete
        case ocrRequested, ocrComplete, historyRequested, historyReady
    }
    enum Outcome: String, Codable, Sendable { case success, failed, canceled }
    enum Launch: String, Codable, Sendable { case cold, resident, unspecified }
    enum Desktop: String, Codable, Sendable { case idle, busy, unspecified }
    enum Interaction: String, Codable, Sendable { case human, automatedUI, controlledHarness, unspecified }
    enum Content: String, Codable, Sendable { case raw, ordinaryEdited, complexEdited, unspecified }

    struct PixelSize: Hashable, Codable, Sendable {
        var width: Int
        var height: Int
    }
    struct Context: Hashable, Codable, Sendable {
        var launch: Launch = .unspecified
        var desktop: Desktop = .unspecified
        var displayCount: Int? = nil
        var inputPixels: PixelSize? = nil
        var outputPixels: PixelSize? = nil
        var interaction: Interaction = .unspecified
        var content: Content = .unspecified
    }
    enum Span: String, Codable, CaseIterable, Sendable {
        case shortcutToSelector, selectionToEditor, copyToClipboard, saveRequestedToComplete, ocrRequestedToComplete
        case regionToPaste, windowArrowToPaste, redactToSave, ocr, historyReuse, historyToEditor

        var endpoints: (Stage, Stage) {
            switch self {
            case .shortcutToSelector: (.captureRequested, .selectorReady)
            case .selectionToEditor: (.selectionCommitted, .editorReady)
            case .copyToClipboard: (.copyRequested, .clipboardReady)
            case .saveRequestedToComplete: (.saveRequested, .saveComplete)
            case .ocrRequestedToComplete: (.ocrRequested, .ocrComplete)
            case .regionToPaste, .windowArrowToPaste: (.captureRequested, .pasteVerified)
            case .redactToSave: (.captureRequested, .saveComplete)
            case .ocr: (.captureRequested, .ocrComplete)
            case .historyReuse: (.historyRequested, .pasteVerified)
            case .historyToEditor: (.historyRequested, .historyReady)
            }
        }
        var targetMilliseconds: Double? {
            switch self {
            case .shortcutToSelector: 150
            case .selectionToEditor: 50
            case .copyToClipboard: 200
            default: nil
            }
        }
        func applies(to workflow: Workflow) -> Bool {
            switch self {
            case .regionToPaste: workflow == .regionToPaste
            case .windowArrowToPaste: workflow == .windowArrowToPaste
            case .redactToSave: workflow == .redactToSave
            case .ocr: workflow == .ocr
            case .historyReuse, .historyToEditor: workflow == .historyReuse
            case .shortcutToSelector:
                [.regionCapture, .regionToPaste, .ocr, .quickCopy].contains(workflow)
            case .selectionToEditor:
                [.regionCapture, .regionToPaste, .windowCapture, .windowArrowToPaste, .redactToSave].contains(workflow)
            case .copyToClipboard:
                [.regionToPaste, .windowArrowToPaste, .historyReuse, .regionCapture, .windowCapture, .fullscreenCapture, .quickCopy].contains(workflow)
            case .saveRequestedToComplete:
                [.redactToSave, .regionCapture, .windowCapture, .fullscreenCapture, .scrollCapture].contains(workflow)
            case .ocrRequestedToComplete: workflow == .ocr
            }
        }
    }
    struct Event: Codable, Sendable {
        var stage: Stage
        var offsetMilliseconds: Double
    }
    struct Measurement: Codable, Sendable {
        var span: Span
        var milliseconds: Double
    }
    struct Run: Codable, Sendable {
        var id: UUID
        var workflow: Workflow
        var context: Context
        var outcome: Outcome
        var durationMilliseconds: Double
        var events: [Event]
        var measurements: [Measurement]
        var actions: Int?
        var corrections: Int?
        var cpuMilliseconds: Double?
        var residentStartBytes: UInt64?
        var residentEndBytes: UInt64?
        /// This is the process lifetime high-water RSS, NOT a per-run peak.
        var peakResidentBytes: UInt64?
        var processCPUPercent: Double? {
            guard let cpuMilliseconds, durationMilliseconds > 0 else { return nil }
            return cpuMilliseconds / durationMilliseconds * 100
        }
    }
    enum Gate: String, Codable, Sendable {
        case withinSoftwareTarget, exceedsSoftwareTarget, insufficientSamples, incompleteEvidence, notApplicable
    }
    struct Summary: Codable, Sendable {
        var workflow: Workflow
        var context: Context
        var span: Span
        var sampleCount: Int
        var successfulRunsMissingSpan: Int
        var failedRuns: Int
        var canceledRuns: Int
        var medianMilliseconds: Double?
        var p95Milliseconds: Double?
        var minimumMilliseconds: Double?
        var maximumMilliseconds: Double?
        var targetMilliseconds: Double?
        var gate: Gate
    }
    struct Environment: Codable, Sendable {
        var operatingSystem: String
        var processorCount: Int
        var physicalMemoryBytes: UInt64
        var buildConfiguration: String
        var appVersion: String
        static func capture() -> Self {
            let process = ProcessInfo.processInfo
            let version = process.operatingSystemVersion
            #if DEBUG
            let build = "Debug"
            #else
            let build = "Release"
            #endif
            return Self(operatingSystem: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
                        processorCount: process.activeProcessorCount, physicalMemoryBytes: process.physicalMemory,
                        buildConfiguration: build,
                        appVersion: String((Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown").prefix(64)))
        }
    }
    struct Report: Codable, Sendable {
        var schemaVersion = 1
        var captureLatencyTrace: CaptureLatencyTrace.Report? = nil
        var measurementMethod = "software-readiness; physical presentation and paste require separate observation"
        var environment: Environment
        var runs: [Run]
        var summaries: [Summary]
        var droppedRuns: Int
        var droppedActiveRuns: Int
        var activeRuns: Int
    }

    private struct ActiveRun {
        var id: UUID
        var workflow: Workflow
        var context: Context
        var started: UInt64
        var resourceStart: WorkflowResourceSample
        var events: [Stage: UInt64] = [:]
        var actions = 0
        var corrections = 0
        var actionsWereObserved = false
    }
    private let capacity: Int
    private let activeCapacity: Int
    private let now: () -> UInt64
    private let resources: () -> WorkflowResourceSample
    private var active: [ActiveRun] = []
    private var completed: [Run] = []
    private var droppedRuns = 0
    private var droppedActiveRuns = 0
    private(set) var currentRunID: UUID?
    /// A benchmark operator must label conditions explicitly; production defaults
    /// remain unspecified rather than guessing cold/resident or desktop load.
    var defaultContext = Context()

    init(capacity: Int = 512, activeCapacity: Int = 16,
         now: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
         resources: @escaping () -> WorkflowResourceSample = { .capture() }) {
        self.capacity = max(1, min(4096, capacity))
        self.activeCapacity = max(1, min(64, activeCapacity))
        self.now = now
        self.resources = resources
    }

    @discardableResult
    func begin(workflow: Workflow, context: Context? = nil) -> UUID {
        if active.count == activeCapacity {
            active.removeFirst()
            droppedActiveRuns += 1
        }
        let id = UUID()
        active.append(ActiveRun(id: id, workflow: workflow, context: context ?? defaultContext, started: now(), resourceStart: resources()))
        currentRunID = id
        return id
    }

    /// Explicit IDs are required for overlapping captures/exports. Omitting the
    /// ID marks the newest active run; with no active run this is a cheap no-op.
    @discardableResult
    func mark(_ stage: Stage, for id: UUID? = nil) -> Bool {
        guard let id = id ?? currentRunID, let index = active.firstIndex(where: { $0.id == id }), active[index].events[stage] == nil else { return false }
        let time = now()
        guard time >= active[index].started else { return false }
        active[index].events[stage] = time
        return true
    }

    func action(for id: UUID? = nil, correction: Bool = false) {
        guard let id = id ?? currentRunID, let index = active.firstIndex(where: { $0.id == id }) else { return }
        active[index].actions = min(1_000_000, active[index].actions + 1)
        active[index].actionsWereObserved = true
        if correction { active[index].corrections = min(1_000_000, active[index].corrections + 1) }
    }

    func update(workflow: Workflow? = nil, context: Context? = nil, for id: UUID? = nil) {
        guard let id = id ?? currentRunID, let index = active.firstIndex(where: { $0.id == id }) else { return }
        if let workflow { active[index].workflow = workflow }
        if let context { active[index].context = context }
    }

    func finish(_ id: UUID? = nil, outcome: Outcome) {
        guard let id = id ?? currentRunID, let index = active.firstIndex(where: { $0.id == id }) else { return }
        let end = now(), resourceEnd = resources()
        let run = active.remove(at: index)
        if currentRunID == id { currentRunID = active.last?.id }
        func milliseconds(from start: UInt64, to end: UInt64) -> Double { Double(end >= start ? end - start : 0) / 1_000_000 }
        let measurements = Span.allCases.filter { $0.applies(to: run.workflow) }.compactMap { span -> Measurement? in
            let endpoints = span.endpoints
            guard let start = run.events[endpoints.0], let end = run.events[endpoints.1], end >= start else { return nil }
            return Measurement(span: span, milliseconds: milliseconds(from: start, to: end))
        }
        let cpu: Double?
        if let start = run.resourceStart.cpuNanoseconds, let end = resourceEnd.cpuNanoseconds, end >= start {
            cpu = milliseconds(from: start, to: end)
        } else { cpu = nil }
        let result = Run(id: id, workflow: run.workflow, context: run.context, outcome: outcome,
            durationMilliseconds: milliseconds(from: run.started, to: end),
            events: Stage.allCases.compactMap { stage in run.events[stage].map { Event(stage: stage, offsetMilliseconds: milliseconds(from: run.started, to: $0)) } },
            measurements: measurements, actions: run.actionsWereObserved ? run.actions : nil,
            corrections: run.actionsWereObserved ? run.corrections : nil,
            cpuMilliseconds: cpu, residentStartBytes: run.resourceStart.residentBytes,
            residentEndBytes: resourceEnd.residentBytes, peakResidentBytes: resourceEnd.peakResidentBytes)
        if completed.count == capacity { completed.removeFirst(); droppedRuns += 1 }
        completed.append(result)
    }

    func reset() {
        active.removeAll(keepingCapacity: false)
        completed.removeAll(keepingCapacity: false)
        droppedRuns = 0
        droppedActiveRuns = 0
        currentRunID = nil
    }

    func snapshot() -> Report {
        struct Group: Hashable { var workflow: Workflow; var context: Context }
        let groups = Dictionary(grouping: completed) { Group(workflow: $0.workflow, context: $0.context) }
        var summaries: [Summary] = []
        for (key, runs) in groups {
            for span in Span.allCases where span.applies(to: key.workflow) {
                let successes = runs.filter { $0.outcome == .success }
                let values = successes.compactMap { $0.measurements.first(where: { $0.span == span })?.milliseconds }.sorted()
                let count = values.count
                let median: Double? = count == 0 ? nil : (count.isMultiple(of: 2) ? (values[count / 2 - 1] + values[count / 2]) / 2 : values[count / 2])
                let p95 = count == 0 ? nil : values[max(0, Int(ceil(Double(count) * 0.95)) - 1)]
                let missing = successes.count - count
                let target = span.targetMilliseconds
                let failed = runs.filter { $0.outcome == .failed }.count
                let eligibleCopy = span != .copyToClipboard ||
                    (key.context.content == .ordinaryEdited && key.context.inputPixels == key.context.outputPixels &&
                     key.context.inputPixels?.height == 2160 && [3840, 4096].contains(key.context.inputPixels?.width ?? 0))
                let gate: Gate
                if target == nil || key.context.launch != .resident || !eligibleCopy { gate = .notApplicable }
                else if missing > 0 || failed > 0 || droppedRuns > 0 || droppedActiveRuns > 0 ||
                            key.context.desktop == .unspecified || key.context.displayCount == nil ||
                            ![.human, .automatedUI].contains(key.context.interaction) { gate = .incompleteEvidence }
                else if count < 30 { gate = .insufficientSamples }
                else { gate = p95! <= target! ? .withinSoftwareTarget : .exceedsSoftwareTarget }
                summaries.append(Summary(workflow: key.workflow, context: key.context, span: span, sampleCount: count,
                    successfulRunsMissingSpan: missing, failedRuns: failed,
                    canceledRuns: runs.filter { $0.outcome == .canceled }.count,
                    medianMilliseconds: median, p95Milliseconds: p95, minimumMilliseconds: values.first,
                    maximumMilliseconds: values.last, targetMilliseconds: target, gate: gate))
            }
        }
        summaries.sort { ($0.workflow.rawValue, $0.context.launch.rawValue, $0.context.desktop.rawValue, $0.context.displayCount ?? 0, $0.span.rawValue) <
            ($1.workflow.rawValue, $1.context.launch.rawValue, $1.context.desktop.rawValue, $1.context.displayCount ?? 0, $1.span.rawValue) }
        return Report(environment: .capture(), runs: completed, summaries: summaries, droppedRuns: droppedRuns,
                      droppedActiveRuns: droppedActiveRuns, activeRuns: active.count)
    }

    /// Explicit user/benchmark export only. Does not create parent directories.
    func export(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snapshot()).write(to: url, options: .atomic)
    }
}
