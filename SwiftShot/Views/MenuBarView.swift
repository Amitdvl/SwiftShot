import SwiftUI

/// The menu-bar popover is deliberately opaque. On macOS 26, an unstyled
/// SwiftUI hierarchy inside an NSPopover can inherit a low-contrast glass
/// treatment that makes controls look disabled even when they are available.
struct MenuBarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 12) {
            header

            VStack(spacing: 6) {
                regionCaptureButton
                captureButton(.window)
                captureButton(.fullscreen)
            }

            Menu {
                Button("Copy Text from Screen", systemImage: "text.viewfinder") {
                    Task { await appState.capture(mode: .ocr) }
                }
                .disabled(appState.isCapturing)

                Button("Scrolling Capture…", systemImage: "scroll") {
                    Task { await appState.capture(mode: .region, scrollingCapture: true) }
                }
                .disabled(appState.isCapturing)

                Button("Recapture Last Region", systemImage: "arrow.counterclockwise") {
                    Task { await appState.captureLastRegion() }
                }
                .disabled(appState.lastRegion == nil || appState.isCapturing)
            } label: {
                MenuBarOptionRow(
                    icon: "ellipsis.circle",
                    title: "More capture options",
                    detail: "Text, scrolling, or repeat"
                )
            }
            .menuStyle(.borderlessButton)
            .disabled(appState.isCapturing)

            Divider()

            HStack(spacing: 8) {
                Button { appState.showPreferences() } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .keyboardShortcut(",", modifiers: [.command])

                Spacer(minLength: 0)

                Button(role: .destructive) { NSApp.terminate(nil) } label: {
                    Label("Quit", systemImage: "power")
                }
                .keyboardShortcut("q", modifiers: [.command])
            }
            .buttonStyle(MenuBarFooterButtonStyle())
        }
        .padding(14)
        .frame(width: 320)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "viewfinder.circle.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
                .font(.system(size: 27, weight: .medium))

            VStack(alignment: .leading, spacing: 2) {
                Text("SwiftShot")
                    .font(.system(size: 15, weight: .semibold))
                Text(appState.isCapturing ? "Capture in progress" : "Ready to capture")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
    }

    private var regionCaptureButton: some View {
        Button { Task { await appState.capture(mode: .region) } } label: {
            MenuBarCaptureRow(
                icon: CaptureMode.region.icon,
                title: CaptureMode.region.label,
                shortcut: "⌘⇧2",
                primary: true
            )
        }
        // Carbon hot keys are swallowed while this popover tracks. Keep the
        // native equivalent so the default shortcut still works while open.
        .keyboardShortcut("2", modifiers: [.command, .shift])
        .buttonStyle(MenuBarCaptureButtonStyle(primary: true))
        .disabled(appState.isCapturing)
    }

    private func captureButton(_ mode: CaptureMode) -> some View {
        Button { Task { await appState.capture(mode: mode) } } label: {
            MenuBarCaptureRow(icon: mode.icon, title: mode.label)
        }
        .buttonStyle(MenuBarCaptureButtonStyle())
        .disabled(appState.isCapturing)
    }
}

private struct MenuBarCaptureRow: View {
    let icon: String
    let title: String
    var shortcut: String? = nil
    var primary = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 22)

            Text(title)
                .font(.system(size: 14, weight: primary ? .semibold : .medium))

            Spacer(minLength: 0)

            if let shortcut {
                Text(shortcut)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
    }
}

private struct MenuBarOptionRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 22)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private struct MenuBarCaptureButtonStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .foregroundStyle(primary && isEnabled ? Color.white : Color.primary)
            .background(background(configuration), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(border(configuration), lineWidth: 0.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .opacity(isEnabled ? 1 : 0.5)
    }

    private func background(_ configuration: Configuration) -> Color {
        if primary {
            return Color.accentColor.opacity(configuration.isPressed ? 0.78 : 1)
        }
        return Color(nsColor: .controlBackgroundColor).opacity(configuration.isPressed ? 0.72 : 1)
    }

    private func border(_ configuration: Configuration) -> Color {
        if primary { return Color.accentColor.opacity(configuration.isPressed ? 0.8 : 0.45) }
        return Color.primary.opacity(configuration.isPressed ? 0.16 : 0.08)
    }
}

private struct MenuBarFooterButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(configuration.role == .destructive ? Color.red : Color.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                configuration.isPressed ? Color.primary.opacity(0.09) : .clear,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .opacity(isEnabled ? 1 : 0.5)
    }
}
