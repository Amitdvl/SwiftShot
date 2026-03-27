import AppKit
import SwiftUI

// MARK: - Notification Service

@MainActor
enum NotificationService {

    private static var panel: NSPanel?
    private static var actionPanel: NSPanel?
    private static var autoSaveTask: Task<Void, Never>?

    static func requestAuthorization() {}

    // MARK: - Capture Action Panel

    static func showCaptureActions(onCopy: @escaping () -> Void, onSave: @escaping () -> Void) {
        dismissCaptureActions()

        let view = CaptureActionView(
            onCopy: {
                NotificationService.dismissCaptureActions()
                onCopy()
            },
            onSave: {
                NotificationService.dismissCaptureActions()
                onSave()
            }
        )
        let hosting = NSHostingView(rootView: view)
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
        p.ignoresMouseEvents = false
        p.alphaValue = 0

        p.orderFrontRegardless()
        actionPanel = p

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            p.animator().alphaValue = 1
        }

        // Auto-save after 6 seconds if no interaction
        autoSaveTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            guard actionPanel != nil else { return }
            NotificationService.dismissCaptureActions()
            onSave()
        }
    }

    static func dismissCaptureActions() {
        autoSaveTask?.cancel()
        autoSaveTask = nil
        if let p = actionPanel {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                p.animator().alphaValue = 0
            }
            p.orderOut(nil)
            p.contentView = nil
            actionPanel = nil
        }
    }

    // MARK: - Toast (used for OCR status etc.)

    static func showToast(title: String, subtitle: String) {
        dismissToast()

        let toast = ToastView(title: title, subtitle: subtitle)
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
            dismissToast()
        }
    }

    private static func dismissToast() {
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
    }
}

// MARK: - Capture Action View

private struct CaptureActionView: View {
    let onCopy: () -> Void
    let onSave: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "camera.viewfinder")
                .font(.title2)
                .foregroundStyle(.primary)

            Text("Screenshot ready")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)

            Spacer(minLength: 16)

            Button("Copy") {
                onCopy()
            }
            .controlSize(.small)

            Button("Save") {
                onSave()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .modifier(LiquidGlassModifier())
    }
}

// MARK: - Toast View

private struct ToastView: View {
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "camera.viewfinder")
                .font(.title2)
                .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
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
