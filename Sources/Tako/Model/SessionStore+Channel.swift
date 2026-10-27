import Foundation

/// A message on its way through a session's channel.
struct ChannelMessage: Equatable {
    /// Short and unique for this run of Tako, e.g. "c7": what the poller acknowledges.
    let id: String
    let text: String
    let sentAt: Date

    @MainActor private static var issued = 0

    @MainActor init(text: String, sentAt: Date = Date()) {
        Self.issued += 1
        id = "c\(Self.issued)"
        self.text = text
        self.sentAt = sentAt
    }
}

/// Channel delivery: each Claude session's `ht mcp` long-polls for messages and pushes them into
/// Claude as channel events. A hand-off used to count as delivered, but a poller that died with
/// a message in hand lost it silently. A poller new enough to confirm acknowledges each message
/// once it has written it to Claude; only then is it recorded delivered, and one not confirmed
/// within `channelConfirmWindow` is typed instead. An older `ht` never acks, and keeps the old
/// behaviour.
extension SessionStore {
    /// How long a queued message waits for a poller to pick it up before it is typed instead.
    static let channelPickupWindow: TimeInterval = 15
    /// How long a confirming poller has to acknowledge a message it picked up.
    static let channelConfirmWindow: TimeInterval = 30

    /// A poll from `session`'s MCP server. `acks` (nil from an older `ht`) confirms what the
    /// previous poll handed it.
    func subscribeChannel(_ session: TerminalSession, acks: [String]? = nil, reply: @escaping ControlServer.Reply) {
        channelLastSeen[session.id] = Date()
        if let acks {
            channelConfirming.insert(session.id)
            acks.forEach { channelConfirmed($0, by: session) }
        } else {
            channelConfirming.remove(session.id)
        }
        if let queued = channelInbox.removeValue(forKey: session.id), !queued.isEmpty {
            reply(handOff(queued, to: session))
            return
        }
        channelWaiters.removeValue(forKey: session.id)?(ControlResponse.success())
        channelWaiters[session.id] = reply
        let token = UUID()
        channelWaiterTokens[session.id] = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in
            guard let self, self.channelWaiterTokens[session.id] == token,
                  let waiting = self.channelWaiters.removeValue(forKey: session.id) else { return }
            self.channelWaiterTokens[session.id] = nil
            waiting(ControlResponse.success())
        }
    }

    /// Forgets a session's channel: its MCP server is gone (closed or restarted). Returns the
    /// messages it never picked up.
    @discardableResult
    func dropChannel(for session: TerminalSession) -> [String] {
        channelWaiters.removeValue(forKey: session.id)?(ControlResponse.success())
        channelWaiterTokens[session.id] = nil
        channelLastSeen[session.id] = nil
        channelConfirming.remove(session.id)
        return (channelInbox.removeValue(forKey: session.id) ?? []).map(\.text)
    }

    /// Pushes a message as a channel event when the session's channel is live. Returns false when
    /// the session has no channel, so the caller types the message instead.
    func pushViaChannel(_ text: String, to session: TerminalSession) -> Bool {
        // A poller from before a restart, sleep or exit can look fresh for a minute while its
        // socket is already gone: only a running agent's channel counts.
        if case .exited = session.state { return false }
        guard Self.channelsEnabled, session.kind == .claude, !session.isAsleep, session.state != .starting,
              let seen = channelLastSeen[session.id], Date().timeIntervalSince(seen) < 60 else { return false }
        // At rest, a channel event starts a turn of its own with no prompt hook to say whose it is;
        // mid-turn, it lands inside the user's turn, where it could pose as the user asking. Either
        // way the rest of this turn no longer counts as the user's for user_requested.
        if session.isSumi { session.turnFromUser = false }
        let message = ChannelMessage(text: text)
        if let waiter = channelWaiters.removeValue(forKey: session.id) {
            waiter(handOff([message], to: session))
            return true
        }
        channelInbox[session.id, default: []].append(message)
        // A poller that died inside the freshness window never drains this: if the message is
        // still waiting, call the channel dead and type it instead.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.channelPickupWindow) { [weak self, weak session] in
            guard let self, let session, var inbox = self.channelInbox[session.id],
                  let index = inbox.firstIndex(where: { $0.id == message.id }) else { return }
            inbox.remove(at: index)
            self.channelInbox[session.id] = inbox.isEmpty ? nil : inbox
            self.channelLastSeen[session.id] = nil
            self.sentMessages.update(message.id, .typedInstead)
            _ = session.deliver(text, from: nil)
        }
        return true
    }

    /// Whether `session`'s poller confirms delivery, so a hand-off isn't yet "delivered".
    func channelConfirms(_ session: TerminalSession) -> Bool { channelConfirming.contains(session.id) }

    private func handOff(_ messages: [ChannelMessage], to session: TerminalSession) -> ControlResponse {
        var response = ControlResponse.success()
        response.messages = messages.map(\.text)
        response.messageIDs = messages.map(\.id)
        guard channelConfirming.contains(session.id) else { return response }
        for message in messages {
            channelUnconfirmed[message.id] = (session.id, message)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.channelConfirmWindow) { [weak self] in
                self?.channelConfirmationDue(message.id)
            }
        }
        return response
    }

    private func channelConfirmed(_ id: String, by session: TerminalSession) {
        guard let pending = channelUnconfirmed[id], pending.session == session.id else { return }
        channelUnconfirmed[id] = nil
        sentMessages.update(id, .delivered)
        EventLog.record("message", session: session.label, "\(id) delivered (channel)",
                        fields: ["id": id, "outcome": "delivered", "via": "channel",
                                 "waited_s": Int(Date().timeIntervalSince(pending.message.sentAt))])
    }

    /// The poller took the message but never said it reached Claude: the channel is called dead
    /// (later messages are typed until it polls again) and this one is typed instead.
    func channelConfirmationDue(_ id: String) {
        guard let pending = channelUnconfirmed.removeValue(forKey: id) else { return }
        sentMessages.update(id, .typedInstead)
        guard let session = sessions.first(where: { $0.id == pending.session }) else {
            EventLog.record("message", "\(id) not confirmed by the channel; its terminal closed",
                            fields: ["id": id, "outcome": "not confirmed", "via": "channel"])
            return
        }
        channelLastSeen[session.id] = nil
        let result = session.deliver(pending.message.text, from: nil)
        EventLog.record("message", session: session.label, "\(id) not confirmed by the channel; typed instead: \(result)",
                        fields: ["id": id, "outcome": "not confirmed", "via": "channel"])
    }
}
