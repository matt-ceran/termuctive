import Foundation
import UserNotifications

/// Posts macOS notifications for cloud agents that need a person, such as a Claude
/// Code session waiting for permission while its laptop window is hidden.
enum CloudNotifications {
    static func post(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else {
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            center.add(
                UNNotificationRequest(
                    identifier: UUID().uuidString,
                    content: content,
                    trigger: nil
                )
            )
        }
    }
}
