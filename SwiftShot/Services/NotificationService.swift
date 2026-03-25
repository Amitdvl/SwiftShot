import Foundation
import UserNotifications

// MARK: - Notification Service

/// Manages local push notifications for screenshot events.
enum NotificationService {

    /// Request notification authorization. Call once at app launch.
    /// Uses `.provisional` so notifications are delivered immediately
    /// without requiring the user to approve a system dialog first.
    static func requestAuthorization() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .provisional]) { granted, error in
            if let error {
                print("[NotificationService] authorization error: \(error.localizedDescription)")
            } else {
                print("[NotificationService] authorization granted: \(granted)")
            }
        }
    }

    /// Post a mutable notification after a successful screenshot capture.
    static func notifyScreenshotSaved(filename: String) {
        let content = UNMutableNotificationContent()
        content.title = "Screenshot Saved"
        content.body = filename
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil // deliver immediately
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("[NotificationService] delivery error: \(error.localizedDescription)")
            }
        }
    }
}
