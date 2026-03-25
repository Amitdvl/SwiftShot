import SwiftUI

// MARK: - Preferences View

struct PreferencesView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        TabView {
            generalTab
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            shortcutsTab
                .tabItem {
                    Label("Shortcuts", systemImage: "keyboard")
                }
        }
        .frame(width: 480, height: 380)
    }

    // MARK: - General Tab

    private var generalTab: some View {
        @Bindable var state = appState

        return Form {
            Section("Save Location") {
                HStack {
                    Text(appState.appSettings.saveDirectory)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    Button("Choose...") {
                        chooseSaveDirectory()
                    }
                }
            }

            Section("Clipboard") {
                Toggle("Copy to clipboard after save", isOn: $state.appSettings.copyToClipboard)
                    .onChange(of: appState.appSettings.copyToClipboard) {
                        appState.saveSettings()
                    }
            }

            Section("Background") {
                let backgrounds = BackgroundCompositor.availableBackgrounds()

                HStack(spacing: 10) {
                    // "None" option
                    backgroundTile(
                        selected: appState.appSettings.backgroundName.isEmpty,
                        label: "None"
                    ) {
                        Image(systemName: "xmark")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .frame(width: 80, height: 50)
                    } action: {
                        state.appSettings.backgroundName = ""
                        appState.saveSettings()
                    }

                    ForEach(backgrounds) { bg in
                        backgroundTile(
                            selected: appState.appSettings.backgroundName == bg.name,
                            label: bg.displayName
                        ) {
                            if let thumb = bg.loadThumbnail(height: 50) {
                                Image(nsImage: thumb)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 80, height: 50)
                                    .clipped()
                            }
                        } action: {
                            state.appSettings.backgroundName = bg.name
                            appState.saveSettings()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Shortcuts Tab

    private var shortcutsTab: some View {
        @Bindable var state = appState

        return Form {
            Section("Capture Shortcuts") {
                ForEach(Array(appState.appSettings.shortcuts.enumerated()), id: \.element.id) { index, shortcut in
                    HStack {
                        let captureMode = CaptureMode(rawValue: shortcut.mode)
                        Text(captureMode?.label ?? shortcut.mode)

                        Spacer()

                        Text(shortcut.displayString)
                            .font(.caption.monospaced())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))

                        Toggle("", isOn: Binding(
                            get: { shortcut.enabled },
                            set: { newVal in
                                state.appSettings.shortcuts[index].enabled = newVal
                                appState.saveSettings()
                                appState.registerShortcuts()
                            }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                    }
                }
            }

            Section {
                Text("Shortcuts are active globally, even when SwiftShot is in the background.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Background Tile

    private func backgroundTile<Content: View>(
        selected: Bool,
        label: String,
        @ViewBuilder content: () -> Content,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                content()
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2)
                    )
                Text(label)
                    .font(.caption2)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func chooseSaveDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Choose where to save screenshots"

        if panel.runModal() == .OK, let url = panel.url {
            appState.appSettings.saveDirectory = url.path
            appState.saveSettings()
        }
    }
}
