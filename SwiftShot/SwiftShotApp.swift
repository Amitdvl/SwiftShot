import SwiftUI

@main
struct SwiftShotApp: App {
    @State private var appState = AppState.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("SwiftShot", systemImage: "camera.viewfinder") {
            MenuBarView().environment(appState)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppState.shared.showPreferences()
        return true
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        AppState.shared.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let document = AppState.shared.lastDocument else { return .terminateNow }
        Task { @MainActor in
            let preserved = await AppState.shared.preserve(document)
            if preserved { sender.reply(toApplicationShouldTerminate: true) }
            else { sender.reply(toApplicationShouldTerminate: false) }
        }
        return .terminateLater
    }
}

struct MenuBarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ForEach(CaptureMode.allCases, id: \.self) { mode in
            Button { Task { await appState.capture(mode: mode) } } label: {
                Label(mode.label, systemImage: mode.icon)
            }
            .disabled(appState.isCapturing)
        }
        Divider()
        Button("Reopen Last Capture") { Task { await appState.reopenLastCapture() } }
            .disabled(appState.lastDocument == nil && appState.recoveredRecords.isEmpty)
        let unsaved = appState.recoveredRecords.filter { $0.savedPath == nil }
        if !unsaved.isEmpty {
            Menu("Recover Unsaved (\(unsaved.count))") {
                ForEach(unsaved) { record in
                    Button(record.createdAt.formatted(date: .abbreviated, time: .standard)) {
                        Task { await appState.reopenRecovery(record.id) }
                    }
                }
            }
        }
        if let url = appState.lastDocument?.savedURL {
            Button("Show Last Save in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        Divider()
        Button("Settings…") { appState.showPreferences() }.keyboardShortcut(",", modifiers: [.command])
        Button("Quit SwiftShot") { NSApp.terminate(nil) }.keyboardShortcut("q", modifiers: [.command])
    }
}
