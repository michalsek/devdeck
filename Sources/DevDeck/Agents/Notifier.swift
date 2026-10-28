import Foundation
import UserNotifications

/// macOS notifications for agent calls that have to wait (with Let Through and Turn Away
/// buttons) and for devices handed over to the user.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    enum Action: String {
        case letThrough = "let-through"
        case turnAway = "turn-away"
    }

    /// A button on a waiting notification, for the waiting call with this id.
    var onAction: ((Action, UUID) -> Void)?
    /// A click on the notification itself.
    var onOpen: ((DashboardPage) -> Void)?

    private let center = UNUserNotificationCenter.current()
    private static let waitingCategory = "waiting"

    func setUp() {
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.waitingCategory,
                actions: [
                    UNNotificationAction(identifier: Action.letThrough.rawValue, title: "Let Through"),
                    UNNotificationAction(identifier: Action.turnAway.rawValue, title: "Turn Away", options: .destructive),
                ],
                intentIdentifiers: []),
        ])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func waiting(_ id: UUID, title: String, body: String, page: DashboardPage) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = Self.waitingCategory
        content.threadIdentifier = "waiting"
        content.userInfo = ["page": page.rawValue]
        post("waiting-" + id.uuidString, content)
    }

    /// Replaces the waiting notification with what happened to the call.
    func gaveUp(_ id: UUID, title: String, body: String, page: DashboardPage) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.threadIdentifier = "waiting"
        content.userInfo = ["page": page.rawValue]
        post("waiting-" + id.uuidString, content)
    }

    /// The call went through (or was cancelled): its notification is no longer news.
    func clear(_ id: UUID) {
        center.removeDeliveredNotifications(withIdentifiers: ["waiting-" + id.uuidString])
    }

    func plain(_ identifier: String, title: String, body: String, page: DashboardPage) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = ["page": page.rawValue]
        post(identifier, content)
    }

    private func post(_ identifier: String, _ content: UNNotificationContent) {
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Show banners even while DevDeck is the active app.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let identifier = response.notification.request.identifier
        let action = response.actionIdentifier
        let page = (response.notification.request.content.userInfo["page"] as? String).flatMap(DashboardPage.init)
        await MainActor.run {
            if let action = Action(rawValue: action),
               let id = UUID(uuidString: identifier.replacingOccurrences(of: "waiting-", with: "")) {
                onAction?(action, id)
            } else if action == UNNotificationDefaultActionIdentifier, let page {
                onOpen?(page)
            }
        }
    }
}
