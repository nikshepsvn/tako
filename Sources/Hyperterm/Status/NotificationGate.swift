import Foundation

/// Decides which banners go out. Tako posted 533 notifications in ~47 hours (50 in the worst
/// hour) with only a 4 s per-session throttle: agents flapping between states, the same
/// "finished" several times in one turn, banners for a tile the user was looking at, and a
/// burst of agents each getting their own. Pure, so the rules are testable without
/// UserNotifications.
struct NotificationGate {
    enum Kind: String {
        /// Waiting on the user: always timely, never limited to once per turn.
        case needsYou
        case finished, failed, crashed
        /// An agent's own heads-up (notify_user).
        case note
    }

    struct Item: Equatable {
        var sessionID: UUID
        var label: String
        var kind: Kind
        var title: String
        var body: String
    }

    /// What to show: one item's banner, or several coalesced into one.
    struct Delivery: Equatable {
        var sessionID: UUID
        var title: String
        var body: String
        var count: Int
    }

    /// Any two banners for one session at least this far apart: agents flap between states.
    static let flapInterval: TimeInterval = 4
    /// The same kind for one session repeats only after a new turn, or after this long for
    /// agents whose turns Tako can't see.
    static let repeatInterval: TimeInterval = 10 * 60
    /// After a banner, others wait this long and go out together as one.
    static let burstWindow: TimeInterval = 5

    private var lastPosted: [UUID: Date] = [:]
    private var told: [UUID: [Kind: Date]] = [:]
    private var pending: [Item] = []
    private var lastDelivery: Date?

    var hasPending: Bool { !pending.isEmpty }

    /// A new turn: the session may tell the user each kind once more.
    mutating func turnStarted(_ sessionID: UUID) {
        told[sessionID] = nil
    }

    enum Decision: Equatable {
        case deliver(Delivery)
        /// Held for coalescing; call `flush` at this time.
        case hold(until: Date)
        case drop
    }

    mutating func offer(_ item: Item, now: Date) -> Decision {
        if let last = lastPosted[item.sessionID], now.timeIntervalSince(last) < Self.flapInterval { return .drop }
        if item.kind != .needsYou, let last = told[item.sessionID]?[item.kind],
           now.timeIntervalSince(last) < Self.repeatInterval { return .drop }
        lastPosted[item.sessionID] = now
        told[item.sessionID, default: [:]][item.kind] = now
        // A newer word from the same session replaces what it had waiting.
        pending.removeAll { $0.sessionID == item.sessionID }
        if let last = lastDelivery, now.timeIntervalSince(last) < Self.burstWindow {
            pending.append(item)
            return .hold(until: last + Self.burstWindow)
        }
        lastDelivery = now
        return .deliver(Self.single(item))
    }

    /// Everything held since the last banner, as one.
    mutating func flush(now: Date) -> Delivery? {
        guard let first = pending.first else { return nil }
        let items = pending
        pending = []
        lastDelivery = now
        guard items.count > 1 else { return Self.single(first) }
        let kinds = Set(items.map(\.kind))
        let title: String
        if kinds == [.finished] {
            title = "\(items.count) agents finished"
        } else if kinds.isSubset(of: [.needsYou]) {
            title = "\(items.count) agents need you"
        } else {
            title = "\(items.count) agents need your attention"
        }
        let body = items.map { "@\($0.label) " + Self.verb($0.kind) }.joined(separator: " · ")
        // The first waiting agent is the one a click opens.
        let target = items.first { $0.kind == .needsYou } ?? first
        return Delivery(sessionID: target.sessionID, title: title, body: body, count: items.count)
    }

    private static func single(_ item: Item) -> Delivery {
        Delivery(sessionID: item.sessionID, title: item.title, body: item.body, count: 1)
    }

    private static func verb(_ kind: Kind) -> String {
        switch kind {
        case .needsYou: return "needs you"
        case .finished: return "finished"
        case .failed: return "failed"
        case .crashed: return "crashed"
        case .note: return "has news"
        }
    }
}
