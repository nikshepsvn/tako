import Foundation

/// What became of the messages each agent sent, for its Activity tab: the sender's side of the
/// receipts Tako types back to it. In memory and bounded (`perSender` per agent, `senders`
/// agents), so it costs nothing when nobody messages; events.jsonl keeps the durable record.
@MainActor
final class SentMessageLog: ObservableObject {
    static let perSender = 20
    static let senders = 40

    enum Outcome: Equatable {
        /// Typed into the target's prompt right away.
        case delivered
        /// Waiting in the target's queue for it to be free.
        case queued
        /// Handed to the target's channel, which hasn't confirmed it reached Claude yet.
        case channelUnconfirmed
        /// Still queued after a long while; it lands when the target is free.
        case stillWaiting
        /// The channel never confirmed it, so Tako typed it instead.
        case typedInstead
        case dropped(String)

        var title: String {
            switch self {
            case .delivered: return "delivered"
            case .queued: return "queued"
            case .channelUnconfirmed: return "channel unconfirmed"
            case .stillWaiting: return "still waiting"
            case .typedInstead: return "typed instead"
            case .dropped: return "dropped"
            }
        }

        /// Settled: nothing more will happen to it.
        var isFinal: Bool {
            switch self {
            case .delivered, .typedInstead, .dropped: return true
            default: return false
            }
        }
    }

    struct Entry: Identifiable, Equatable {
        let id = UUID()
        /// Tako's id for it ("m12" queued, "c7" channel); nil when it was typed straight in.
        var messageID: String?
        let target: String
        let preview: String
        let sentAt: Date
        var outcome: Outcome
        var updatedAt: Date
    }

    /// Sender label → its messages, newest last.
    @Published private(set) var bySender: [String: [Entry]] = [:]
    /// Message id → sender, to find an entry when its outcome arrives.
    private var senderOf: [String: String] = [:]

    func entries(for sender: String) -> [Entry] { bySender[sender] ?? [] }

    func record(_ entry: Entry, from sender: String) {
        var list = bySender[sender] ?? []
        list.append(entry)
        if list.count > Self.perSender {
            for old in list.prefix(list.count - Self.perSender) { if let id = old.messageID { senderOf[id] = nil } }
            list.removeFirst(list.count - Self.perSender)
        }
        bySender[sender] = list
        if let id = entry.messageID { senderOf[id] = sender }
        if bySender.count > Self.senders, let stalest = bySender.min(by: { ($0.value.last?.updatedAt ?? .distantPast) < ($1.value.last?.updatedAt ?? .distantPast) })?.key {
            for old in bySender.removeValue(forKey: stalest) ?? [] { if let id = old.messageID { senderOf[id] = nil } }
        }
    }

    /// A later outcome for message `id`. Ignored for messages no agent sent, or already settled
    /// (a late "still waiting" mustn't undo "delivered").
    func update(_ id: String, _ outcome: Outcome, at now: Date = Date()) {
        guard let sender = senderOf[id], var list = bySender[sender],
              let index = list.lastIndex(where: { $0.messageID == id }), !list[index].outcome.isFinal else { return }
        list[index].outcome = outcome
        list[index].updatedAt = now
        bySender[sender] = list
    }
}

extension SessionStore {
    /// send_message's reply to an agent, read back as an outcome. `framed` is the text handed to
    /// `deliver`, which finds the channel message's id when it went that way.
    func noteSent(_ reply: String, text framed: String, preview: String, from sender: TerminalSession,
                  to target: TerminalSession, now: Date = Date()) {
        let outcome: SentMessageLog.Outcome
        var id: String?
        if reply.hasPrefix("Queued (message ") {
            outcome = .queued
            id = reply.dropFirst("Queued (message ".count).split(separator: ")").first.map(String.init)
        } else if reply.hasSuffix("(channel)") {
            id = channelMessageID(framed, to: target)
            outcome = reply.hasPrefix("sent to") ? .channelUnconfirmed : .delivered
        } else if reply.hasPrefix("not delivered: ") {
            outcome = .dropped(String(reply.dropFirst("not delivered: ".count)))
        } else if reply.hasPrefix("delivered to") {
            outcome = .delivered
        } else {
            return
        }
        sentMessages.record(.init(messageID: id, target: target.label, preview: String(preview.prefix(120)),
                                  sentAt: now, outcome: outcome, updatedAt: now), from: sender.label)
    }

    /// The id of the channel message just handed to (or waiting for) `target`'s poller.
    private func channelMessageID(_ text: String, to target: TerminalSession) -> String? {
        if let waiting = channelInbox[target.id]?.last(where: { $0.text == text }) { return waiting.id }
        return channelUnconfirmed.first { $0.value.session == target.id && $0.value.message.text == text }?.key
    }
}
