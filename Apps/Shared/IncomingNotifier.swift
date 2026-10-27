import Foundation
import TossCore
import UserNotifications

enum IncomingNotifier {
    static func post(item: TransferItem, sender: TrustedDevice?) async {
        guard sender?.notificationsEnabled == true else { return }
        let content = UNMutableNotificationContent()
        content.title = "New Toss from \(sender?.name ?? "your device")"
        if UserDefaults.standard.bool(forKey: "notification-previews-v1") {
            content.body = item.title
        } else {
            content.body = item.kind == .file || item.kind == .image ? "A file is ready in your inbox." : "Open Toss to view it."
        }
        content.sound = .default
        let request = UNNotificationRequest(identifier: item.id.uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}

final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationPresenter()

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
