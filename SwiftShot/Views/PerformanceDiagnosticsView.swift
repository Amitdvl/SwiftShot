import SwiftUI

struct PerformanceDiagnosticsView: View {
    @Bindable var diagnostics: PerformanceDiagnostics
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section {
                Toggle("Enable for This Session", isOn: Binding(get: { diagnostics.isEnabled }, set: { diagnostics.setEnabled($0) }))
                Text("Off by default. In-memory metadata only; no screenshots, OCR text, capture paths, polling or automatic files.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Run Conditions") {
                Picker("Workflow", selection: $diagnostics.selection.workflow) {
                    ForEach(WorkflowPerformance.Workflow.allCases, id: \.self) { Text($0.diagnosticLabel).tag($0) }
                }
                Picker("Process", selection: $diagnostics.selection.context.launch) {
                    Text("Not specified").tag(WorkflowPerformance.Launch.unspecified)
                    Text("Resident").tag(WorkflowPerformance.Launch.resident)
                    Text("Cold — first workflow after relaunch").tag(WorkflowPerformance.Launch.cold)
                }
                Picker("Desktop", selection: $diagnostics.selection.context.desktop) {
                    Text("Not specified").tag(WorkflowPerformance.Desktop.unspecified)
                    Text("Idle").tag(WorkflowPerformance.Desktop.idle)
                    Text("Busy").tag(WorkflowPerformance.Desktop.busy)
                }
                Picker("Interaction", selection: $diagnostics.selection.context.interaction) {
                    Text("Not specified").tag(WorkflowPerformance.Interaction.unspecified)
                    Text("Human interaction").tag(WorkflowPerformance.Interaction.human)
                    Text("Automated UI").tag(WorkflowPerformance.Interaction.automatedUI)
                    Text("Controlled harness — not live E2E").tag(WorkflowPerformance.Interaction.controlledHarness)
                }
                Picker("Image Content", selection: $diagnostics.selection.context.content) {
                    Text("Not specified").tag(WorkflowPerformance.Content.unspecified)
                    Text("Raw").tag(WorkflowPerformance.Content.raw)
                    Text("Ordinary edited").tag(WorkflowPerformance.Content.ordinaryEdited)
                    Text("Complex edited").tag(WorkflowPerformance.Content.complexEdited)
                }
                Picker("Displays", selection: $diagnostics.selection.context.displayCount) {
                    Text("Not specified").tag(Int?.none)
                    ForEach(1...16, id: \.self) { Text("\($0)").tag(Int?.some($0)) }
                }
                Text("Conditions are operator-supplied and frozen at Begin Run. Relaunch between cold samples; process-launch latency is not measured here.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(!diagnostics.isEnabled || diagnostics.activeRunID != nil)

            Section("Current Run") {
                Button("Begin Run") { diagnostics.beginRun() }
                    .disabled(!diagnostics.isEnabled || diagnostics.activeRunID != nil)
                if let workflow = diagnostics.activeWorkflow {
                    LabeledContent("Armed Workflow", value: workflow.diagnosticLabel)
                    LabeledContent("Input Pixels", value: pixels(diagnostics.activeContext?.inputPixels))
                    LabeledContent("Output Pixels", value: pixels(diagnostics.activeContext?.outputPixels))
                    if workflow == .idleObservation {
                        Text("Leave the app unchanged for the chosen observation interval, then finish. This panel does not run a timer or background sampler.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !diagnostics.activeStages.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Recorded stages").font(.caption).foregroundStyle(.secondary)
                            ForEach(diagnostics.activeStages, id: \.self) { stage in
                                Label(stage.rawValue, systemImage: "checkmark").font(.caption.monospaced())
                            }
                        }
                    }
                    if !diagnostics.missingStages.isEmpty {
                        Text("Missing: " + diagnostics.missingStages.map(\.rawValue).joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button("Mark Paste Verified") { diagnostics.verifyPaste() }
                    .disabled(diagnostics.activeRunID == nil || diagnostics.activeStages.contains(.pasteVerified))
                    .help("Press only after checking the correct image in the destination app. Clipboard readiness is not paste verification.")
                Text("Verify only after the destination contains the correct image. The timestamp includes your delay before this button press; it is not the exact paste or physical-display time.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("+1 Action") { diagnostics.action() }
                    Button("+1 Correction") { diagnostics.action(correction: true) }
                }.disabled(diagnostics.activeRunID == nil)
                Text("Actions: \(count(diagnostics.observedActions)) · Corrections: \(count(diagnostics.observedCorrections))")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Count observed workflow actions, not these diagnostics buttons. A correction includes one action. Do not double-count actions already recorded by hooks.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Finish Success") { diagnostics.finish(outcome: .success) }
                    Button("Fail") { diagnostics.finish(outcome: .failed) }
                    Button("Cancel Run") { diagnostics.finish(outcome: .canceled) }
                }.disabled(diagnostics.activeRunID == nil)
            }

            Section("Evidence") {
                Text(diagnostics.lastMessage).font(.callout).textSelection(.enabled)
                Text("Retained: \(diagnostics.completedCount) · Failed: \(diagnostics.failedCount) · Canceled: \(diagnostics.canceledCount) · Dropped: \(diagnostics.droppedCount)")
                    .font(.caption).foregroundStyle(.secondary)
                if diagnostics.activeRunID == nil && !diagnostics.lastMissingStages.isEmpty {
                    Text("Last run missing: " + diagnostics.lastMissingStages.map(\.rawValue).joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Software timings and operator observations are not physical-display proof. Use 30+ comparable samples per condition and retain failures. CPU/RSS include the whole armed interval and other process work.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Export JSON…") { diagnostics.exportWithSavePanel() }
                        .disabled(diagnostics.isExporting || (diagnostics.completedCount == 0 && diagnostics.activeRunID == nil))
                    Button("Clear Results…") { confirmClear = true }
                        .disabled(diagnostics.completedCount == 0 || diagnostics.activeRunID != nil)
                }
                Text("Closing this window only hides it. An active run continues until finished or diagnostics are disabled. Export during a run reports it as unfinished.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Clear retained diagnostic metadata?", isPresented: $confirmClear) {
            Button("Clear Results", role: .destructive) { diagnostics.clearResults() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Export first if you need these samples. This only clears in-memory diagnostic results, not captures or saved files.")
        }
    }

    private func pixels(_ value: WorkflowPerformance.PixelSize?) -> String {
        value.map { "\($0.width) × \($0.height)" } ?? "Not measured"
    }
    private func count(_ value: Int?) -> String { value.map(String.init) ?? "not observed" }
}

private extension WorkflowPerformance.Workflow {
    var diagnosticLabel: String {
        switch self {
        case .regionToPaste: "Region → Paste"
        case .windowArrowToPaste: "Window → Arrow → Paste"
        case .redactToSave: "Redact → Save"
        case .ocr: "OCR"
        case .historyReuse: "History Reuse → Paste"
        case .regionCapture: "Region Capture"
        case .windowCapture: "Window Capture"
        case .fullscreenCapture: "Fullscreen Capture"
        case .quickCopy: "Quick Copy"
        case .scrollCapture: "Scrolling Capture"
        case .idleObservation: "Idle CPU Observation"
        }
    }
}
