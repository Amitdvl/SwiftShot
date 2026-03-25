import Foundation

// MARK: - Notification Service

enum NotificationService {

    static func requestAuthorization() {
        // No authorization needed for osascript notifications
    }

    static func notifyScreenshotSaved(filename: String) {
        let escaped = filename.replacingOccurrences(of: "\"", with: "\\\"")
        let script = "display notification \"\(escaped)\" with title \"Screenshot Saved\""

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }
}
