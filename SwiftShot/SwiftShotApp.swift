import SwiftUI
import OSLog

@main
struct SwiftShotApp: App {
    @State private var appState = AppState.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var statusPopover: NSPopover?
    private let logger = Logger(subsystem: "com.swiftshot.app", category: "StatusItem")

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppState.shared.showPreferences()
        return true
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        // MenuBarExtra apps have no ordinary window for AppKit's automatic
        // termination heuristic to count as user-visible activity. SwiftShot
        // must stay resident so its status item and global shortcuts remain
        // available after launch.
        ProcessInfo.processInfo.automaticTerminationSupportEnabled = true
        ProcessInfo.processInfo.disableAutomaticTermination("SwiftShot menu bar app")
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        installStatusItem()
        AppState.shared.start()
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // Give AppKit one stable identity for visibility and position across
        // launches instead of relying on its generated Item-0 fallback.
        item.autosaveName = "SwiftShot"
        // Retain the item before asking Control Center for its asynchronously
        // hosted button. Otherwise a temporarily missing button deallocates the
        // only status item and leaves the app running with no menu-bar entry.
        statusItem = item
        configureStatusItem(item, retriesRemaining: 10)
    }

    private func configureStatusItem(_ item: NSStatusItem, retriesRemaining: Int) {
        guard item === statusItem else { return }
        guard let button = item.button else {
            guard retriesRemaining > 0 else {
                logger.error("Status item button never became available")
                return
            }
            Task { @MainActor [weak self, weak item] in
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, let item else { return }
                self.configureStatusItem(item, retriesRemaining: retriesRemaining - 1)
            }
            return
        }

        button.image = NSImage(systemSymbolName: "viewfinder.circle", accessibilityDescription: "SwiftShot")
        button.image?.isTemplate = true
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = "SwiftShot"
        button.target = self
        button.action = #selector(toggleStatusPopover(_:))
        item.isVisible = true
        logger.info("Installed status item; visible=\(item.isVisible, privacy: .public)")
    }

    @objc private func toggleStatusPopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if let statusPopover, statusPopover.isShown {
            statusPopover.performClose(sender)
            return
        }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 280, height: 400)
        popover.contentViewController = NSHostingController(
            rootView: MenuBarView()
                .environment(AppState.shared)
                .padding(.vertical, 8)
                .frame(width: 280)
        )
        statusPopover = popover
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            let preserved = await AppState.shared.prepareToQuit()
            if preserved { sender.reply(toApplicationShouldTerminate: true) }
            else { sender.reply(toApplicationShouldTerminate: false) }
        }
        return .terminateLater
    }
}

struct MenuBarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ForEach([CaptureMode.region, .window, .fullscreen], id: \.self) { mode in
            if mode == .region {
                Button { Task { await appState.capture(mode: mode) } } label: {
                    Label(mode.label, systemImage: mode.icon)
                }
                // Carbon hot keys are swallowed while this status menu tracks.
                // The region default is also a native menu key equivalent, so
                // pressing ⌘⇧2 while the dropdown is open starts the same
                // capture action before AppKit dismisses the menu.
                .keyboardShortcut("2", modifiers: [.command, .shift])
                .disabled(appState.isCapturing)
            } else {
                Button { Task { await appState.capture(mode: mode) } } label: {
                    Label(mode.label, systemImage: mode.icon)
                }
                .disabled(appState.isCapturing)
            }
        }
        Menu("More Capture Options") {
            Button("Copy Text from Screen", systemImage: "text.viewfinder") {
                Task { await appState.capture(mode: .ocr) }
            }.disabled(appState.isCapturing)
            Button("Scrolling Capture…", systemImage: "scroll") {
                Task { await appState.capture(mode: .region, scrollingCapture: true) }
            }.disabled(appState.isCapturing)
            Button("Recapture Last Region") { Task { await appState.captureLastRegion() } }
                .disabled(appState.lastRegion == nil || appState.isCapturing)
        }
        Divider()
        Button("Settings…") { appState.showPreferences() }.keyboardShortcut(",", modifiers: [.command])
        Button("Quit SwiftShot") { NSApp.terminate(nil) }.keyboardShortcut("q", modifiers: [.command])
    }
}
