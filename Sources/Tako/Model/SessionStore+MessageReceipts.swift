import Foundation

/// A message waiting for its agent to be free.
struct QueuedMessage: Equatable {
    /// Short and unique for this run of Tako, e.g. "m12": what the sender was told.
    let id: String
    let text: String
    /// The sending agent's label; nil for the user, Tako itself or a digest.
    let sender: String?
    let queuedAt: Date
    /// Its sender has been told it is still waiting, so that is said once, not every poll.
    var staleNoticed = false

    @MainActor private static var issued = 0

    @MainActor init(text: String, sender: String?, queuedAt: Date = Date()) {
        Self.issued += 1
        id = "m\(Self.issued)"
        self.text = text
        self.sender = sender
        self.queuedAt = queuedAt
    }
}

/// How a queued message ended.
enum MessageOutcome: Equatable {
    case delivered
    case dropped(String)
    /// Still waiting after a long time. It stays queued: a long build mustn't cost a message.
    case stale(String)
}

/// Receipts gathered per sender, so a burst of deliveries is one line, not one turn each.
struct MessageReceipts {
    static let window: TimeInterval = 5
    var pending: [String: [String]] = [:]
}

/// Tells an agent what became of a message that was queued instead of delivered. send_message
/// used to answer "queued: …" and the sender, reading that as sent, moved on: 13 messages sat
/// in queues and were never delivered, and the user found out from an agent that never got
/// its instructions.
extension SessionStore {
    func messageOutcome(_ message: QueuedMessage, to target: TerminalSession, _ outcome: MessageOutcome) {
        let waited = Int(Date().timeIntervalSince(message.queuedAt))
        let (result, why): (String, String?) = {
            switch outcome {
            case .delivered: return ("delivered", nil)
            case .dropped(let why): return ("dropped", why)
            case .stale(let why): return ("still queued", why)
            }
        }()
        if message.sender != nil {
            switch outcome {
            case .delivered: sentMessages.update(message.id, .delivered)
            case .dropped(let why): sentMessages.update(message.id, .dropped(why))
            case .stale: sentMessages.update(message.id, .stillWaiting)
            }
        }
        EventLog.record("message", session: target.label, "\(message.id) \(result)" + (why.map { ": " + $0 } ?? ""),
                        fields: ["id": message.id, "from": message.sender ?? "-", "outcome": result, "waited_s": waited])
        guard let senderLabel = message.sender,
              let sender = sessions.first(where: { $0.label == senderLabel }), sender.id != target.id else { return }
        let receipt = Self.receipt(message, target: target.label, outcome: outcome, waited: waited)
        if sender.isSumi {
            addToSumiDigest(SumiEvent(label: target.label, kind: .messageReceipt(receipt)))
            return
        }
        let first = messageReceipts.pending[senderLabel] == nil
        messageReceipts.pending[senderLabel, default: []].append(receipt)
        guard first else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + MessageReceipts.window) { [weak self] in
            self?.sendReceipts(to: senderLabel)
        }
    }

    /// Everything queued for a terminal that is closing will never arrive.
    func messagesDropped(from session: TerminalSession, reason: String) {
        session.takeQueue().forEach { messageOutcome($0, to: session, .dropped(reason)) }
    }

    func sendReceipts(to senderLabel: String) {
        guard let receipts = messageReceipts.pending.removeValue(forKey: senderLabel), !receipts.isEmpty,
              let sender = sessions.first(where: { $0.label == senderLabel }) else { return }
        _ = sender.deliver("Tako: " + receipts.joined(separator: "; "), from: nil)
    }

    /// One clause per message, phrased so "not delivered" can't be misread.
    static func receipt(_ message: QueuedMessage, target: String, outcome: MessageOutcome, waited: Int) -> String {
        let after = waited >= 60 ? " after \(waited / 60) min" : ""
        switch outcome {
        case .delivered:
            return "your message \(message.id) reached @\(target)\(after)"
        case .stale(let why):
            return "your message \(message.id) to @\(target) is still queued (\(why)); it lands when @\(target) is free, so only resend if your plans changed"
        case .dropped(let why):
            return "your message \(message.id) to @\(target) was NOT delivered (\(why)); resend it if it still matters: \"\(String(message.text.prefix(80)))\""
        }
    }
}
