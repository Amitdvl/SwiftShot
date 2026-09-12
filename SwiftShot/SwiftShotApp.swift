import SwiftUI
import OSLog

@main
struct SwiftShotApp: App {
    @State private var appState = AppState.shared
    @State private var testMenuBarExtraIsInserted = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // XCTest needs the SwiftUI menu-bar scene to establish a regular
        // AppKit test host. The running app owns its status item directly.
        MenuBarExtra("SwiftShot", systemImage: "camera.viewfinder", isInserted: $testMenuBarExtraIsInserted) {
            EmptyView()
        }
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
        // XCTest hosts also instantiate the app delegate. Leave their activation
        // controls and status item untouched; their AppKit fixtures take over
        // from the same accessory policy as the live menu-bar app.
        NSApp.setActivationPolicy(.accessory)
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        installStatusItem()
        AppState.shared.start()
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "com.swiftshot.statusItem"
        item.behavior = []
        item.isVisible = true
        guard let button = item.button else { return }
        button.image = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        if button.image == nil {
            button.image = NSImage(named: NSImage.applicationIconName)
                ?? NSImage(systemSymbolName: "camera.fill", accessibilityDescription: "SwiftShot")
        }
        button.image?.isTemplate = false
        button.imageScaling = .scaleProportionallyDown
        button.title = "SwiftShot"
        button.imagePosition = .imageLeft
        button.toolTip = "SwiftShot"
        button.target = self
        button.action = #selector(toggleStatusPopover(_:))
        statusItem = item
        logger.info("Installed status item; visible=\(item.isVisible, privacy: .public), title=\(button.title, privacy: .public)")
    }

    @objc private func toggleStatusPopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if let statusPopover, statusPopover.isShown {
            statusPopover.performClose(sender)
            return
        }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
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
