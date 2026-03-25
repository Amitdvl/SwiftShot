import AppKit
import SwiftUI

// MARK: - HUD Controller

/// Displays a temporary centered overlay (HUD) for critical alerts.
@MainActor
enum HUDController {

    private static var panel: NSPanel?

    /// macOS 15+ renamed the pane to "Screen & System Audio Recording".
    private static var screenRecordingPaneName: String {
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15 {
            return "Screen & System Audio Recording"
        }
        return "Screen Recording"
    }

    static func showPermissionDenied() {
        dismissCurrent()

        let paneName = screenRecordingPaneName

        let view = HUDView(
            icon: "lock.shield",
            title: "\(paneName) Off",
            message: "Enable SwiftShot in\nPrivacy & Security \u{2192} \(paneName)",
            actionLabel: "Open Settings",
            action: {
                dismissCurrent()
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
            }
        )

        let hosting = NSHostingView(rootView: view)
        hosting.setFrameSize(hosting.fittingSize)

        let p = NSPanel(
            contentRect: NSRect(origin: .zero, size: hosting.frame.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.contentView = hosting
        p.backgroundColor = .clear
        p.isOpaque = false
        p.level = .floating
        p.isFloatingPanel = true
        p.hasShadow = true
        p.center()

        p.makeKeyAndOrderFront(nil)
        panel = p

        // Auto-dismiss after 5 seconds
        Task {
            try? await Task.sleep(for: .seconds(5))
            dismissCurrent()
        }
    }

    private static func dismissCurrent() {
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
    }
}

// MARK: - HUD View

private struct HUDView: View {
    let icon: String
    let title: String
    let message: String
    let actionLabel: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(.white)

            VStack(spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)

                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
            }

            Button(actionLabel, action: action)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(28)
        .frame(width: 280)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .environment(\.colorScheme, .dark)
    }
}
