import Foundation
import UserNotifications

// MARK: - Notification Service

enum NotificationService {

    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func notifyScreenshotSaved(filename: String) {
        let content = UNMutableNotificationContent()
        content.title = "Screenshot Saved"
        content.body = filename
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}
