import SwiftUI

struct WorkflowPresetsView: View {
    @Environment(AppState.self) private var appState
    @State private var workflow: CaptureWorkflow = .region
    @State private var presetName = ""

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Workflow")
                    Spacer()
                    Picker("Workflow", selection: $workflow) {
                        ForEach(CaptureWorkflow.allCases, id: \.self) { value in
                            Text(value.label).tag(value)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Menu {
                        Button("Use Raw Pixels", systemImage: "circle.slash") {
                            updateStyle(CaptureStyle())
                        }
                        if let document = appState.lastDocument {
                            Button("Use Last Capture's Style", systemImage: "clock.arrow.circlepath") {
                                updateStyle(document.edits.style)
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .buttonStyle(CaptureButtonStyle(compact: true))
                    .accessibilityLabel("Style Actions")
                }
            }
            Section("Background") {
                BackgroundPickerView(library: appState.backgrounds, selection: Binding(get: {
                    appState.appSettings.style(for: workflow).backgroundID
                }, set: { id in
                    var style = appState.appSettings.style(for: workflow)
                    style.backgroundID = id; updateStyle(style)
                }), showsHeader: false, showsImportButton: true,
                   showsLibraryActions: false, gridHeight: 132)
            }
            Section("Style") {
                slider("Padding", key: \.padding, range: 0...240)
                slider("Corners", key: \.cornerRadius, range: 0...64)
                slider("Shadow", key: \.shadow, range: 0...64)
            }
            Section {
                HStack {
                    TextField("Name this style", text: $presetName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(savePreset)
                    Button("Save", systemImage: "plus") { savePreset() }
                        .buttonStyle(CaptureButtonStyle(prominent: true))
                        .disabled(!canSavePreset)
                }
                ForEach(appState.appSettings.presets) { preset in
                    HStack {
                        Image(systemName: "wand.and.stars")
                            .foregroundStyle(.secondary)
                        Text(preset.name).lineLimit(1)
                        Spacer()
                        Button("Use") { updateStyle(preset.style) }
                            .buttonStyle(CaptureButtonStyle())
                        Button(role: .destructive) {
                            appState.appSettings.presets.removeAll { $0.id == preset.id }
                            appState.saveSettings()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(CaptureButtonStyle(compact: true))
                        .help("Delete \(preset.name)")
                        .accessibilityLabel("Delete \(preset.name)")
                    }
                }
            } header: {
                HStack {
                    Text("Presets")
                    Spacer()
                    Text("\(appState.appSettings.presets.count)/32")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var canSavePreset: Bool {
        !presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            appState.appSettings.presets.count < 32
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
            Text(title).frame(width: 62, alignment: .leading)
            Slider(value: Binding(get: { appState.appSettings.style(for: workflow)[keyPath: key] }, set: { value in
                var style = appState.appSettings.style(for: workflow)
                style[keyPath: key] = value.rounded(); updateStyle(style)
            }), in: range)
            Text("\(Int(appState.appSettings.style(for: workflow)[keyPath: key]))")
                .font(.caption.monospacedDigit())
                .frame(width: 30, alignment: .trailing)
        }
        .font(.caption)
        .disabled(appState.appSettings.style(for: workflow).backgroundID.isEmpty)
    }
}
