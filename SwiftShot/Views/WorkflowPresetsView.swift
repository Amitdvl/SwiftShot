import SwiftUI

struct WorkflowPresetsView: View {
    @Environment(AppState.self) private var appState
    @State private var workflow: CaptureWorkflow = .region
    @State private var presetName = ""

    var body: some View {
        Form {
            Section("Workflow style") {
                Picker("Apply to", selection: $workflow) {
                    ForEach(CaptureWorkflow.allCases, id: \.self) { value in Text(value.label).tag(value) }
                }
                Text("Backgrounds and canvas settings belong to each workflow here, so there is one place to manage them.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Use Raw Pixels") { updateStyle(CaptureStyle()) }
                    if let document = appState.lastDocument {
                        Button("Use Last Capture's Style") { updateStyle(document.edits.style) }
                    }
                }
            }
            Section("Background library") {
                BackgroundPickerView(library: appState.backgrounds, selection: Binding(get: {
                    appState.appSettings.style(for: workflow).backgroundID
                }, set: { id in
                    var style = appState.appSettings.style(for: workflow)
                    style.backgroundID = id; updateStyle(style)
                }))
                .frame(maxHeight: 270)
            }
            Section("Canvas") {
                slider("Padding", key: \.padding, range: 0...240)
                slider("Corners", key: \.cornerRadius, range: 0...64)
                slider("Shadow", key: \.shadow, range: 0...64)
            }
            Section("Named presets") {
                HStack {
                    TextField("Preset name", text: $presetName).textFieldStyle(.roundedBorder)
                    Button("Save Preset") { savePreset() }
                        .disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || appState.appSettings.presets.count >= 32)
                }
                ForEach(appState.appSettings.presets) { preset in
                    HStack {
                        Text(preset.name)
                        Spacer()
                        Button("Apply") { updateStyle(preset.style) }
                        Button("Delete", role: .destructive) {
                            appState.appSettings.presets.removeAll { $0.id == preset.id }; appState.saveSettings()
                        }
                    }
                }
                Text("Up to 32 presets. Deleting one does not change existing captures.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func updateStyle(_ style: CaptureStyle) {
        appState.appSettings.setStyle(style, for: workflow)
        appState.saveSettings()
    }

    private func savePreset() {
        let name = String(presetName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        guard !name.isEmpty, appState.appSettings.presets.count < 32 else { return }
        appState.appSettings.presets.append(CaptureStylePreset(name: name, style: appState.appSettings.style(for: workflow)))
        appState.saveSettings(); presetName = ""
    }

    private func slider(_ title: String, key: WritableKeyPath<CaptureStyle, Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title).frame(width: 60, alignment: .leading)
            Slider(value: Binding(get: { appState.appSettings.style(for: workflow)[keyPath: key] }, set: { value in
                var style = appState.appSettings.style(for: workflow)
                style[keyPath: key] = value.rounded(); updateStyle(style)
            }), in: range)
            Text("\(Int(appState.appSettings.style(for: workflow)[keyPath: key]))").monospacedDigit().frame(width: 30)
        }.font(.caption).disabled(appState.appSettings.style(for: workflow).backgroundID.isEmpty)
    }
}
