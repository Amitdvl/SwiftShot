import AppKit
import SwiftUI

@MainActor
enum NotificationService {
    private static var panel: NSPanel?
    private static var lifetime: Task<Void, Never>?
    private static var token = UUID()

    static func showToast(title: String, subtitle: String) {
        show(title: title, message: subtitle, isError: false, retry: nil, chooseFolder: nil)
    }

    static func showError(_ message: String, retry: (() -> Void)? = nil, chooseFolder: (() -> Void)? = nil, openSettings: (() -> Void)? = nil) {
        show(title: "Couldn't finish", message: message, isError: true, retry: retry, chooseFolder: chooseFolder, openSettings: openSettings)
    }

    static func dismiss() {
        lifetime?.cancel()
        lifetime = nil
        token = UUID()
        panel?.orderOut(nil)
        panel = nil
    }

    private static func show(title: String, message: String, isError: Bool, retry: (() -> Void)?, chooseFolder: (() -> Void)?, openSettings: (() -> Void)? = nil) {
        dismiss()
        let ownToken = token
        let view = StatusToastView(title: title, message: message, isError: isError,
            retry: retry.map { action in { dismiss(); action() } },
            chooseFolder: chooseFolder.map { action in { dismiss(); action() } },
            openSettings: openSettings.map { action in { dismiss(); action() } }, onClose: dismiss)
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        guard let screen else { return }
        let frame = NSRect(x: screen.visibleFrame.maxX - size.width - 20, y: screen.visibleFrame.maxY - size.height - 20, width: size.width, height: size.height)
        let window = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.contentView = hosting
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.alphaValue = 0
        window.orderFrontRegardless()
        panel = window
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.16
            window.animator().alphaValue = 1
        }
        guard !isError else { return }
        lifetime = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard token == ownToken else { return }
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18
                window.animator().alphaValue = 0
            }
            guard token == ownToken else { return }
            dismiss()
        }
    }
}

private struct StatusToastView: View {
    let title: String
    let message: String
    let isError: Bool
    let retry: (() -> Void)?
    let chooseFolder: (() -> Void)?
    let openSettings: (() -> Void)?
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(isError ? Color.orange : Color.green)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button(action: onClose) { Image(systemName: "xmark") }.buttonStyle(CaptureButtonStyle(compact: true)).help("Dismiss").accessibilityLabel("Dismiss notification")
            }
            if retry != nil || chooseFolder != nil || openSettings != nil {
                HStack {
                    if let retry { Button("Retry", action: retry).buttonStyle(.borderedProminent) }
                    if let chooseFolder { Button("Choose Folder…", action: chooseFolder) }
                    if let openSettings { Button("Open Settings", action: openSettings) }
                }
            }
        }
        .buttonStyle(CaptureButtonStyle())
        .padding(20)
        .frame(width: 340, alignment: .leading)
        .captureChrome()
    }
}
