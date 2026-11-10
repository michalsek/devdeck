import Foundation
import UserNotifications

/// macOS notifications for agent calls that have to wait (with Let Through and Turn Away
/// buttons), for devices handed over to the user, and for stale agent-device claims that
/// turn an agent away (with Release Claim).
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
    /// Release Claim on a stale-claim notification, with the claim's agent-device session.
    var onReleaseClaim: ((String) -> Void)?
    /// Clean Up on a leftovers notification, with the agent session's id.
    var onCleanUp: ((String) -> Void)?

    private let center = UNUserNotificationCenter.current()
    private static let waitingCategory = "waiting"
    private static let claimCategory = "claim"
    private static let releaseClaim = "release-claim"
    private static let leftoversCategory = "leftovers"
    private static let cleanUp = "clean-up"

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
            UNNotificationCategory(
                identifier: Self.claimCategory,
                actions: [UNNotificationAction(identifier: Self.releaseClaim, title: "Release Claim", options: .destructive)],
                intentIdentifiers: []),
            UNNotificationCategory(
                identifier: Self.leftoversCategory,
                actions: [UNNotificationAction(identifier: Self.cleanUp, title: "Clean Up", options: .destructive)],
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

    /// A stale agent-device claim turned an agent away.
    func staleClaim(session: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = Self.claimCategory
        content.userInfo = ["page": DashboardPage.leases.rawValue, "session": session]
        post("claim-" + session, content)
    }

    func clearClaim(session: String) {
        center.removeDeliveredNotifications(withIdentifiers: ["claim-" + session])
    }

    /// A finished agent session left processes or devices running.
    func leftovers(_ session: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = Self.leftoversCategory
        content.userInfo = ["page": DashboardPage.agents.rawValue, "agentSession": session]
        post("leftovers-" + session, content)
    }

    func clearLeftovers(_ session: String) {
        center.removeDeliveredNotifications(withIdentifiers: ["leftovers-" + session])
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
        let session = response.notification.request.content.userInfo["session"] as? String
        let agentSession = response.notification.request.content.userInfo["agentSession"] as? String
        await MainActor.run {
            if action == Self.releaseClaim, let session {
                onReleaseClaim?(session)
            } else if action == Self.cleanUp, let agentSession {
                onCleanUp?(agentSession)
            } else if let action = Action(rawValue: action),
               let id = UUID(uuidString: identifier.replacingOccurrences(of: "waiting-", with: "")) {
                onAction?(action, id)
            } else if action == UNNotificationDefaultActionIdentifier, let page {
                onOpen?(page)
            }
        }
    }
}
