import SwiftUI

struct PreferencesView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            WorkflowPresetsView().tabItem { Label("Presets & Styles", systemImage: "slider.horizontal.3") }
            shortcuts.tabItem { Label("Shortcuts", systemImage: "keyboard") }
            advanced.tabItem { Label("Advanced", systemImage: "ellipsis") }
        }
        // Preferences use native macOS controls so the hierarchy stays quiet and
        // the controls remain compact beside the capture toolbar's branded chrome.
        .frame(width: 620, height: 570)
    }

    private var general: some View {
        @Bindable var state = appState
        return Form {
            Section("Saving") {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Save screenshots to")
                        Text(appState.appSettings.saveDirectory).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button("Choose…") { appState.chooseSaveDirectory() }
                }
                Text("PNG · Native screenshot pixels · Lossless export").font(.caption).foregroundStyle(.secondary)
            }
            Section("After selecting") {
                Toggle("Copy immediately", isOn: $state.appSettings.immediateCopy)
                    .onChange(of: appState.appSettings.immediateCopy) { _, _ in appState.saveSettings() }
                Text("Quick Copy stays in memory and goes straight to the clipboard. Save when you want to keep the image.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Show a recent capture thumbnail", isOn: $state.appSettings.showRecentThumbnail)
                    .onChange(of: appState.appSettings.showRecentThumbnail) { _, _ in appState.saveSettings() }

            }
            Section("Recovery") {
                Toggle("Private captures (no text index)", isOn: $state.appSettings.privateCapture)
                    .onChange(of: appState.appSettings.privateCapture) { _, _ in appState.saveSettings() }
                Toggle("Search capture text locally", isOn: Binding(get: { appState.appSettings.historyIndexingEnabled },
                    set: { enabled in Task { await appState.setHistoryIndexing(enabled) } }))
                Text("Unsaved captures stay in memory. Saved captures keep their editable originals locally. Disabling text search deletes its local index.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let status = appState.statusMessage {
                Section { Text(status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }
        }
        .formStyle(.grouped)
    }

    private var advanced: some View {
        @Bindable var state = appState
        return Form {
            Section("Smaller exports") {
                Picker("Smaller Share maximum dimension", selection: $state.appSettings.shareMaxDimension) {
                    Text("1280 px").tag(1280)
                    Text("2048 px").tag(2048)
                    Text("4096 px").tag(4096)
                }.onChange(of: appState.appSettings.shareMaxDimension) { _, _ in appState.saveSettings() }
            }
            Section("Troubleshooting") {
                Button("Performance Diagnostics…", systemImage: "gauge.with.dots.needle.50percent") {
                    PerformanceDiagnostics.shared.showWindow()
                }
                Text("Optional measurements, off by default. Nothing is exported unless you choose.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }

    private var shortcuts: some View {
        Form {
            Section("Global shortcuts") {
                ForEach(Array(appState.appSettings.shortcuts.enumerated()), id: \.element.id) { index, shortcut in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Label(CaptureMode(rawValue: shortcut.mode)?.label ?? shortcut.mode,
                                  systemImage: CaptureMode(rawValue: shortcut.mode)?.icon ?? "keyboard")
                            Spacer()
                            Text(shortcut.displayString).font(.callout.monospaced())
                                .padding(.horizontal, 8).padding(.vertical, 4).background(.quaternary, in: Capsule())
                            Toggle("Enable \(CaptureMode(rawValue: shortcut.mode)?.label ?? shortcut.mode)", isOn: Binding(
                                get: { appState.appSettings.shortcuts[index].enabled },
                                set: { appState.appSettings.shortcuts[index].enabled = $0; appState.saveSettings(); appState.registerShortcuts() }
                            )).labelsHidden().toggleStyle(.switch)
                        }
                        if let error = appState.shortcutErrors[shortcut.mode] {
                            Text(error).font(.caption).foregroundStyle(.orange)
                            Button("Retry Registration") { appState.registerShortcuts() }.controlSize(.small)
                        }
                    }
                }
            }
            Section("In the capture toolbar") {
                LabeledContent("Copy", value: "⌘C")
                LabeledContent("Save", value: "⌘S")
                LabeledContent("Undo / Redo", value: "⌘Z / ⌘⇧Z")
                LabeledContent("Close tool / Cancel", value: "Esc")
            }
            Text("Shortcuts are registered when SwiftShot launches. Selection is limited to the display where you start dragging, preserving its native resolution.")
                .font(.caption).foregroundStyle(.secondary)
        }.formStyle(.grouped)
    }
}
