import SwiftUI
import UserNotifications

@main
struct SwiftShotApp: App {
    @State private var appState = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("SwiftShot", systemImage: "camera.viewfinder") {
            MenuBarView()
                .environment(appState)
                .onAppear {
                    appDelegate.appState = appState
                    appState.registerShortcuts()
                }
        }

        Settings {
            PreferencesView()
                .environment(appState)
        }
    }
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var appState: AppState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Show in Dock so user can right-click → Keep in Dock
        NSApp.setActivationPolicy(.regular)

        // Set up notifications
        UNUserNotificationCenter.current().delegate = self
        NotificationService.requestAuthorization()
    }

    // Show notifications even when the app is in the foreground
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

// MARK: - Menu Bar View

struct MenuBarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Button("Capture Region") {
            Task { await appState.capture(mode: .region) }
        }

        Button("Capture Fullscreen") {
            Task { await appState.capture(mode: .fullscreen) }
        }

        Button("Capture Window") {
            Task { await appState.capture(mode: .window) }
        }

        Button("OCR Region") {
            Task { await appState.capture(mode: .ocr) }
        }

        Divider()

        SettingsLink {
            Text("Preferences...")
        }
        .keyboardShortcut(",", modifiers: [.command])

        Divider()

        Button("Quit SwiftShot") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: [.command])
    }
}
