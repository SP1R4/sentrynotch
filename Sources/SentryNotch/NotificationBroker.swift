import Foundation
import SentryNotchCore
import UserNotifications

/// System-notification answers: posts each pending permission prompt as a
/// notification with Deny / Allow Once / Always actions, so you can answer from
/// the toast (or Notification Centre) without focusing the notch — useful when
/// it's on another Space or the display was asleep.
///
/// Fail-open and defensive: it only arms when running as a real .app bundle
/// (a loose unsigned binary would raise inside `UNUserNotificationCenter`), and
/// every failure is swallowed — the notch stays the primary answer surface.
@MainActor
final class NotificationBroker: NSObject, UNUserNotificationCenterDelegate {
    /// (requestID, decision) where decision ∈ {"allow","deny","always"}.
    var onAction: ((UUID, String) -> Void)?

    private static let category = "\(Brand.slug.uppercased())_PROMPT"
    private var available = false

    func start() {
        // A loose binary has no bundle identity; touching the notification
        // centre there throws an ObjC exception we can't catch. Gate on it.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let deny = UNNotificationAction(identifier: "DENY", title: "Deny",
                                        options: [.destructive])
        let allow = UNNotificationAction(identifier: "ALLOW_ONCE", title: "Allow Once",
                                         options: [.authenticationRequired])
        let always = UNNotificationAction(identifier: "ALLOW_ALWAYS", title: "Always Allow",
                                          options: [.authenticationRequired])
        let category = UNNotificationCategory(
            identifier: Self.category, actions: [deny, allow, always],
            intentIdentifiers: [], options: [])
        center.setNotificationCategories([category])

        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in self?.available = granted }
        }
    }

    /// Post (or replace) the notification for a pending prompt.
    func post(id: UUID, title: String, tool: String, summary: String, highRisk: Bool) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title.isEmpty ? "Claude Code" : title
        content.subtitle = highRisk ? "⚠︎ \(tool) — review before allowing" : tool
        content.body = String(summary.prefix(180))
        content.categoryIdentifier = Self.category
        content.sound = highRisk ? .defaultCritical : .default
        content.userInfo = ["req_id": id.uuidString]

        let request = UNNotificationRequest(identifier: id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Pull a prompt's notification once it's been answered in the notch.
    func withdraw(id: UUID) {
        guard available else { return }
        let ids = [id.uuidString]
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: ids)
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        guard let raw = info["req_id"] as? String, let id = UUID(uuidString: raw) else {
            completionHandler(); return
        }
        let decision: String?
        switch action {
        case "DENY": decision = "deny"
        case "ALLOW_ONCE": decision = "allow"
        case "ALLOW_ALWAYS": decision = "always"
        default: decision = nil   // tap-through: leave it pending in the notch
        }
        Task { @MainActor in
            if let decision { self.onAction?(id, decision) }
            completionHandler()
        }
    }

    /// Show the banner even while the app is frontmost.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
