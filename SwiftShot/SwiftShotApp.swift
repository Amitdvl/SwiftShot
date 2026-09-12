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
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
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
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            // LSUIElement is correct for the installed app, but the XCTest host
            // needs normal activation so its real AppKit windows remain testable.
            NSApp.setActivationPolicy(.regular)
            return
        }
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
        let menu = NSMenu(title: "SwiftShot")
        menu.autoenablesItems = false
        menu.delegate = self
        statusMenu = menu
        item.menu = menu
        rebuildStatusMenu(menu)
        item.isVisible = true
        logger.info("Installed status item; visible=\(item.isVisible, privacy: .public)")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildStatusMenu(menu)
    }

    private func rebuildStatusMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let title = NSMenuItem(title: "SwiftShot", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())

        menu.addItem(actionItem("Capture Region", action: #selector(captureRegion(_:)), keyEquivalent: "2", modifiers: [.command, .shift]))
        menu.addItem(actionItem("Capture Window", action: #selector(captureWindow(_:))))
        menu.addItem(actionItem("Capture Fullscreen", action: #selector(captureFullscreen(_:))))

        let more = NSMenuItem(title: "More Capture Options", action: nil, keyEquivalent: "")
        let moreMenu = NSMenu(title: "More Capture Options")
        moreMenu.autoenablesItems = false
        moreMenu.addItem(actionItem("Copy Text from Screen", action: #selector(captureText(_:))))
        moreMenu.addItem(actionItem("Scrolling Capture…", action: #selector(captureScrolling(_:))))
        let recapture = actionItem("Recapture Last Region", action: #selector(recaptureLastRegion(_:)))
        recapture.isEnabled = AppState.shared.lastRegion != nil && !AppState.shared.isCapturing
        moreMenu.addItem(recapture)
        more.submenu = moreMenu
        more.isEnabled = !AppState.shared.isCapturing
        menu.addItem(more)

        menu.addItem(.separator())
        menu.addItem(actionItem("Settings…", action: #selector(showPreferences(_:)), keyEquivalent: ",", modifiers: [.command]))
        menu.addItem(.separator())
        menu.addItem(actionItem("Quit SwiftShot", action: #selector(quit(_:)), keyEquivalent: "q", modifiers: [.command]))
    }

    private func actionItem(
        _ title: String,
        action: Selector,
        keyEquivalent: String = "",
        modifiers: NSEvent.ModifierFlags = []
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        item.isEnabled = !AppState.shared.isCapturing
        return item
    }

    @objc private func captureRegion(_ sender: Any?) {
        Task { _ = await AppState.shared.capture(mode: .region) }
    }

    @objc private func captureWindow(_ sender: Any?) {
        Task { _ = await AppState.shared.capture(mode: .window) }
    }

    @objc private func captureFullscreen(_ sender: Any?) {
        Task { _ = await AppState.shared.capture(mode: .fullscreen) }
    }

    @objc private func captureText(_ sender: Any?) {
        Task { _ = await AppState.shared.capture(mode: .ocr) }
    }

    @objc private func captureScrolling(_ sender: Any?) {
        Task { _ = await AppState.shared.capture(mode: .region, scrollingCapture: true) }
    }

    @objc private func recaptureLastRegion(_ sender: Any?) {
        Task { await AppState.shared.captureLastRegion() }
    }

    @objc private func showPreferences(_ sender: Any?) {
        AppState.shared.showPreferences()
    }

    @objc private func quit(_ sender: Any?) {
        NSApp.terminate(nil)
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
