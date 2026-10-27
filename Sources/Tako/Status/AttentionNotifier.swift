import AppKit
import UserNotifications

/// macOS notifications and the Dock badge. Clicking a notification focuses its session;
/// approval notifications carry Allow / Deny buttons that answer the agent directly.
@MainActor
final class AttentionNotifier: NSObject, UNUserNotificationCenterDelegate {
    var onActivate: ((UUID) -> Void)?
    var onApprovalAction: ((UUID, PromptAnswer) -> Void)?
    private var lastPosted: [UUID: Date] = [:]

    private static let approvalCategory = "dev.tako.approval"
    private static let allowAction = "allow"
    private static let denyAction = "deny"

    func requestAuthorization() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let allow = UNNotificationAction(identifier: Self.allowAction, title: "Allow", options: [])
        let deny = UNNotificationAction(identifier: Self.denyAction, title: "Deny", options: [.destructive])
        let category = UNNotificationCategory(identifier: Self.approvalCategory, actions: [allow, deny], intentIdentifiers: [], options: [])
        center.setNotificationCategories([category])
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// `foreground` banners also show while Tako is active (for sessions you aren't looking at).
    func post(session: TerminalSession, title: String, body: String, foreground: Bool) {
        if NSApp.isActive && !foreground { return }
        // One banner per session per few seconds; agents can flap between states.
        if let last = lastPosted[session.id], Date().timeIntervalSince(last) < 4 { return }
        lastPosted[session.id] = Date()
        deliver(identifier: UUID().uuidString, session: session, title: title, body: body, category: nil)
    }

    /// An approval banner, always shown: the agent is blocked until someone answers.
    func postApproval(session: TerminalSession, request: String, alwaysRule: String?) {
        let body = alwaysRule.map { "\(request)\n“Always” would allow \($0)" } ?? request
        deliver(identifier: approvalIdentifier(session), session: session, title: "@\(session.label) wants to run", body: body,
                category: Self.approvalCategory)
        if !NSApp.isActive { NSApp.requestUserAttention(.criticalRequest) }
    }

    func clearApproval(session: TerminalSession) {
        let id = approvalIdentifier(session)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
    }

    func updateBadge(count: Int) {
        NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
    }

    private func approvalIdentifier(_ session: TerminalSession) -> String { "approval-\(session.id.uuidString)" }

    private func deliver(identifier: String, session: TerminalSession, title: String, body: String, category: String?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["session": session.id.uuidString]
        content.threadIdentifier = session.id.uuidString
        if let category { content.categoryIdentifier = category }
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
        if !NSApp.isActive && category == nil { NSApp.requestUserAttention(.informationalRequest) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let raw = response.notification.request.content.userInfo["session"] as? String
        let action = response.actionIdentifier
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let raw, let id = UUID(uuidString: raw) else { return }
                switch action {
                case Self.allowAction: self.onApprovalAction?(id, .approve)
                case Self.denyAction: self.onApprovalAction?(id, .deny)
                default:
                    NSApp.activate(ignoringOtherApps: true)
                    self.onActivate?(id)
                }
            }
        }
        completionHandler()
    }
}
