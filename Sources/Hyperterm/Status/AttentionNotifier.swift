import AppKit
import UserNotifications

/// Where banners go. The real Notification Center outside tests; the unit-test host posted
/// ~230 real banners a day, with sound, from `dev.hyperterm.app.dev`, so it gets a sink that
/// drops them (or records them, in tests that check what would be shown).
@MainActor
protocol NotificationSink: AnyObject {
    func add(_ request: UNNotificationRequest)
    func removeDelivered(_ identifiers: [String])
}

@MainActor
final class SystemNotificationSink: NotificationSink {
    func add(_ request: UNNotificationRequest) { UNUserNotificationCenter.current().add(request) }
    func removeDelivered(_ identifiers: [String]) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}

@MainActor
final class RecordingNotificationSink: NotificationSink {
    private(set) var requests: [UNNotificationRequest] = []
    func add(_ request: UNNotificationRequest) { requests.append(request) }
    func removeDelivered(_ identifiers: [String]) {}
}

/// macOS notifications and the Dock badge. Clicking a notification focuses its session;
/// approval notifications carry Allow / Deny buttons that answer the agent directly.
@MainActor
final class AttentionNotifier: NSObject, UNUserNotificationCenterDelegate {
    var onActivate: ((UUID) -> Void)?
    var onApprovalAction: ((UUID, PromptAnswer) -> Void)?
    /// Whether the user is looking at the session right now (its tile on screen in the key
    /// window): a banner would only repeat what they see.
    var isLooking: ((TerminalSession) -> Bool)?
    let sink: NotificationSink
    private var gate = NotificationGate()
    private var flushScheduled = false

    private static let approvalCategory = "dev.hyperterm.approval"
    private static let allowAction = "allow"
    private static let denyAction = "deny"

    init(sink: NotificationSink? = nil) {
        self.sink = sink ?? (TestHost.isActive ? RecordingNotificationSink() : SystemNotificationSink())
    }

    func requestAuthorization() {
        guard sink is SystemNotificationSink else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let allow = UNNotificationAction(identifier: Self.allowAction, title: "Allow", options: [])
        let deny = UNNotificationAction(identifier: Self.denyAction, title: "Deny", options: [.destructive])
        let category = UNNotificationCategory(identifier: Self.approvalCategory, actions: [allow, deny], intentIdentifiers: [], options: [])
        center.setNotificationCategories([category])
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// `foreground` banners also show while Tako is active (for sessions you aren't looking at).
    /// Each goes through the gate: once per turn per kind, never for a session in view, and a
    /// burst becomes one banner.
    func post(session: TerminalSession, title: String, body: String, foreground: Bool,
              kind: NotificationGate.Kind, now: Date = Date()) {
        if NSApp.isActive && !foreground { return }
        if isLooking?(session) == true { return }
        let item = NotificationGate.Item(sessionID: session.id, label: session.label, kind: kind, title: title, body: body)
        switch gate.offer(item, now: now) {
        case .deliver(let delivery): show(delivery)
        case .hold(let until): scheduleFlush(at: until)
        case .drop: break
        }
    }

    /// The session's user turn began: it may tell the user each kind once more.
    func turnStarted(_ session: TerminalSession) { gate.turnStarted(session.id) }

    /// Sends what the gate held back, coalesced.
    func flushHeld(now: Date = Date()) {
        flushScheduled = false
        if let delivery = gate.flush(now: now) { show(delivery) }
    }

    private func scheduleFlush(at date: Date) {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.1, date.timeIntervalSinceNow)) { [weak self] in
            self?.flushHeld()
        }
    }

    private func show(_ delivery: NotificationGate.Delivery) {
        deliver(identifier: UUID().uuidString, sessionID: delivery.sessionID, title: delivery.title, body: delivery.body, category: nil)
    }

    /// An approval banner, always shown: the agent is blocked until someone answers.
    func postApproval(session: TerminalSession, request: String, alwaysRule: String?) {
        // The dialog is on screen in front of them.
        if isLooking?(session) == true { return }
        let body = alwaysRule.map { "\(request)\n“Always” would allow \($0)" } ?? request
        deliver(identifier: approvalIdentifier(session), sessionID: session.id, title: "@\(session.label) wants to run", body: body,
                category: Self.approvalCategory)
        if !NSApp.isActive, sink is SystemNotificationSink { NSApp.requestUserAttention(.criticalRequest) }
    }

    func clearApproval(session: TerminalSession) {
        sink.removeDelivered([approvalIdentifier(session)])
    }

    func updateBadge(count: Int) {
        guard sink is SystemNotificationSink else { return }
        NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
    }

    private func approvalIdentifier(_ session: TerminalSession) -> String { "approval-\(session.id.uuidString)" }

    private func deliver(identifier: String, sessionID: UUID, title: String, body: String, category: String?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["session": sessionID.uuidString]
        content.threadIdentifier = sessionID.uuidString
        if let category { content.categoryIdentifier = category }
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        sink.add(request)
        guard sink is SystemNotificationSink else { return }
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
