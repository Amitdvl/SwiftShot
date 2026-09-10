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
        ForEach(CaptureMode.allCases, id: \.self) { mode in
            Button { Task { await appState.capture(mode: mode) } } label: {
                Label(mode.label, systemImage: mode.icon)
            }
            .disabled(appState.isCapturing)
        }
        Button("Quick Copy Region", systemImage: "document.on.document") {
            Task { await appState.capture(mode: .region, quickCopy: true) }
        }.disabled(appState.isCapturing)
        Button("Private Region Capture", systemImage: "lock.shield") {
            Task { await appState.capture(mode: .region, privateCapture: true) }
        }.disabled(appState.isCapturing)
        Button("Scrolling Capture…", systemImage: "scroll") {
            Task { await appState.capture(mode: .region, scrollingCapture: true) }
        }.disabled(appState.isCapturing)
        Divider()
        Button("Reopen Last Capture") { Task { await appState.reopenLastCapture() } }
            .disabled(appState.lastDocument == nil && appState.recoveredRecords.isEmpty)
        Button("Recapture Last Region") { Task { await appState.captureLastRegion() } }
            .disabled(appState.lastRegion == nil || appState.isCapturing)
        Button("Capture History…", systemImage: "clock.arrow.circlepath") { appState.showHistory() }
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
        Button("Performance Diagnostics…", systemImage: "gauge.with.dots.needle.50percent") {
            PerformanceDiagnostics.shared.showWindow()
        }
        Button("Settings…") { appState.showPreferences() }.keyboardShortcut(",", modifiers: [.command])
        Button("Quit SwiftShot") { NSApp.terminate(nil) }.keyboardShortcut("q", modifiers: [.command])
    }
}
