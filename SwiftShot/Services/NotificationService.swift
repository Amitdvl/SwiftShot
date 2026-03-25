import AppKit
import SwiftUI

// MARK: - Notification Service

@MainActor
enum NotificationService {

    private static var panel: NSPanel?

    static func requestAuthorization() {}

    static func notifyScreenshotSaved(filename: String, copied: Bool = true) {
        dismissCurrent()

        let toast = ToastView(title: "Screenshot Saved", subtitle: filename, copied: copied)
        let hosting = NSHostingView(rootView: toast)
        hosting.setFrameSize(hosting.fittingSize)

        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let x = screenFrame.maxX - hosting.frame.width - 16
        let y = screenFrame.maxY - hosting.frame.height - 12

        let p = NSPanel(
            contentRect: NSRect(x: x, y: y, width: hosting.frame.width, height: hosting.frame.height),
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
        p.collectionBehavior = [.canJoinAllSpaces, .stationary]
        p.ignoresMouseEvents = true
        p.alphaValue = 0

        p.orderFrontRegardless()
        panel = p

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            p.animator().alphaValue = 1
        }

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            await NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                p.animator().alphaValue = 0
            }
            dismissCurrent()
        }
    }

    private static func dismissCurrent() {
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
    }
}

// MARK: - Toast View

private struct ToastView: View {
    let title: String
    let subtitle: String
    let copied: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "camera.viewfinder")
                .font(.title2)
                .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                HStack(spacing: 4) {
                    Text(subtitle)
                        .foregroundStyle(.secondary)
                    if copied {
                        Text("· Copied")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 12))
                .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .modifier(LiquidGlassModifier())
    }
}

private struct LiquidGlassModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content.background(.ultraThinMaterial, in: Capsule())
        }
    }
}
