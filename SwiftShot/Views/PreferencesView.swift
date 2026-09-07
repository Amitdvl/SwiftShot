import SwiftUI

struct PreferencesView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            backgroundTab.tabItem { Label("Backgrounds", systemImage: "photo.on.rectangle.angled") }
            shortcuts.tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .frame(width: 570, height: 540)
    }

    private var general: some View {
        @Bindable var state = appState
        return Form {
            Section {
                HStack {
                    Label("Capture. Finish. Keep moving.", systemImage: "camera.viewfinder").font(.title3.weight(.semibold))
                    Spacer()
                    Menu("Capture") {
                        ForEach(CaptureMode.allCases, id: \.self) { mode in
                            Button(mode.label, systemImage: mode.icon) { Task { await appState.capture(mode: mode) } }
                        }
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .disabled(appState.isCapturing)
                }
                Text("Freeze your screen, select an area, then edit and share from a compact toolbar.")
                    .foregroundStyle(.secondary).font(.callout)
            }
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
                Text("Skip editing and copy with your last style. Reopen Last Capture from the menu bar whenever you need it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Recovery") {
                HStack {
                    Text("Your latest capture stays available after you close the toolbar.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reopen Last Capture") { Task { await appState.reopenLastCapture() } }
                        .disabled(appState.lastDocument == nil && appState.recoveredRecords.isEmpty)
                }
            }
            if let status = appState.statusMessage {
                Section { Text(status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }
        }
        .formStyle(.grouped)
    }

    private var backgroundTab: some View {
        VStack(spacing: 16) {
            StyleSampleView(library: appState.backgrounds, style: appState.appSettings.style)
                .frame(height: 120)
            BackgroundPickerView(library: appState.backgrounds, selection: Binding(
                get: { appState.appSettings.style.backgroundID },
                set: { appState.appSettings.style.backgroundID = $0; appState.saveSettings() }
            ))
            Text("Fine-tune padding, corners, and shadow from the capture toolbar.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
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
                                .padding(.horizontal, 8).padding(.vertical, 4).background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
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

private struct StyleSampleView: View {
    let library: BackgroundLibrary
    let style: CaptureStyle
    var body: some View {
        ZStack {
            if let background = library.thumbnail(for: style.backgroundID) {
                Image(nsImage: background).resizable().scaledToFill()
            } else { Rectangle().fill(.quaternary.opacity(0.4)) }
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 5) {
                    ForEach([Color.red, .yellow, .green], id: \.self) { color in Circle().fill(color.opacity(0.8)).frame(width: 6, height: 6) }
                    Spacer()
                    Text("SwiftShot").font(.caption2).foregroundStyle(.secondary)
                }
                Text("A little more polished.").font(.callout.weight(.medium))
                Text("Original pixels. Your own style.").font(.caption).foregroundStyle(.secondary)
            }
            .padding(14).frame(width: 270)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: style.backgroundID.isEmpty ? 0 : 10))
            .shadow(color: .black.opacity(0.18), radius: style.backgroundID.isEmpty ? 0 : 8, y: 4)
        }
        .clipped().clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityLabel("Background preview")
    }
}
