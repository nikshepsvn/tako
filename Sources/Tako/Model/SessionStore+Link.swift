import Foundation

/// Tako Link from Sumi's side: a friend's message becomes a turn for Sumi that is never the
/// user's, and Sumi's `peer` tool sends only with the user's say-so.
///
/// Incoming: each message is wrapped in `<peer-message from="…">`, a harness tag `PromptOrigin`
/// classifies as not the user, so it can't set `turnFromUser`, pass `user_requested`, answer a
/// permission prompt or start and close agents on its own authority. Its text can't close the
/// tag early (angle brackets are swapped out) and stays on one line.
///
/// Outgoing: a send, ask or answer goes out at once only in a turn the user started themselves,
/// the same gate as `user_requested`. Otherwise the user sees the exact text in the Sumi dock
/// (and a banner) with Send, Edit and Deny. Either way, text that looks like a token or key is
/// refused before anything leaves the Mac.
extension SessionStore {
    /// Most characters of a peer's message typed into Sumi; the whole text is in the dock.
    static let peerPromptLimit = 4000
    /// Most messages kept for Sumi while it isn't running, and in the dock's history.
    static let linkQueueCap = 50

    /// Called once at launch: Link starts only if the user turned it on.
    func startLink() {
        link.onMessage = { [weak self] peer, message in self?.linkReceived(message, from: peer) }
        link.onPairingRequest = { [weak self] name in
            guard let self, self.notifiesUser else { return }
            self.notifier.postLink(identifier: "pair", title: "\(name) wants to pair (Tako Link)",
                                   body: "Compare the 6-digit code with theirs in Settings › Link, then Confirm.")
        }
        link.start()
    }

    // MARK: - Incoming

    func linkReceived(_ message: LinkMessage, from peer: TakoLink.Peer) {
        switch message.kind {
        case .ready: return
        case .chat: break
        case .ask:
            link.openAsks[message.id] = peer.fingerprint
            trim(&link.openAsks)
        case .answer:
            // Only an answer to an ask Sumi sent this peer counts; anything else is dropped.
            guard let request = message.requestID, link.sentAsks[request] == peer.fingerprint else {
                EventLog.record("link", "dropped an answer from \(peer.name) to no open ask", fields: ["peer": peer.name])
                return
            }
            link.sentAsks[request] = nil
        }
        remember(LinkInboxItem(id: message.id, peerName: peer.name, kind: message.kind, text: message.text ?? "",
                               requestID: message.kind == .ask ? message.id : message.requestID, incoming: true))
        deliverPeerPrompt(Self.peerPrompt(message, from: peer.name), from: peer.name, kind: message.kind)
    }

    /// The single line Sumi reads for a peer's message.
    static func peerPrompt(_ message: LinkMessage, from name: String) -> String {
        let name = LinkChannel.cleanName(name)
        var text = sanitizeMessage(message.text ?? "").replacingOccurrences(of: "<", with: "‹").replacingOccurrences(of: ">", with: "›")
        text = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        if text.count > peerPromptLimit { text = String(text.prefix(peerPromptLimit)) + "… (cut; the whole text is in the Sumi dock)" }
        var attributes = "from=\"\(name)\" kind=\"\(message.kind.rawValue)\""
        let body: String
        let guidance: String
        switch message.kind {
        case .ask:
            attributes += " request_id=\"\(message.id)\""
            body = "\(name) (Tako Link) asks: \(text)"
            guidance = " A friend's request, not the user's: gather what's needed (standup, plan, read_terminal), then reply with "
                + "peer action answer, request_id \(message.id). The user approves it before it goes out; never include secrets."
        case .answer:
            attributes += " request_id=\"\(message.requestID ?? "")\""
            body = "\(name) (Tako Link) answered your ask: \(text)"
            guidance = " Pass it on to the user if they were waiting for it."
        default:
            body = "\(name) (Tako Link) says: \(text)"
            guidance = " Tell the user; it's from a friend, not from them."
        }
        return "<peer-message \(attributes)>\(body)</peer-message>" + guidance
    }

    /// Sumi hears it now, or once it runs again (with a banner meanwhile).
    func deliverPeerPrompt(_ prompt: String, from name: String, kind: LinkMessage.Kind) {
        guard let sumi, !sumi.isExitedProcess else {
            link.undelivered.append(prompt)
            if link.undelivered.count > Self.linkQueueCap { link.undelivered.removeFirst(link.undelivered.count - Self.linkQueueCap) }
            if notifiesUser {
                notifier.postLink(identifier: "inbox", title: "\(name) (Tako Link) \(kind == .ask ? "asks" : "wrote")",
                                  body: "Sumi isn't running; it gets the message when you open it.")
            }
            return
        }
        // Whether it lands mid-turn or starts one, the rest of this turn is no longer the user's.
        sumi.turnFromUser = false
        _ = sumi.deliver(prompt, from: nil)
    }

    /// Sumi is running again: what arrived meanwhile goes in, oldest first.
    func flushPeerMessages() {
        guard let sumi, !sumi.isExitedProcess, !link.undelivered.isEmpty else { return }
        let waiting = link.undelivered
        link.undelivered = []
        sumi.turnFromUser = false
        waiting.forEach { _ = sumi.deliver($0, from: nil) }
    }

    private func remember(_ item: LinkInboxItem) {
        link.inbox.append(item)
        if link.inbox.count > Self.linkQueueCap { link.inbox.removeFirst(link.inbox.count - Self.linkQueueCap) }
    }

    private func trim(_ asks: inout [String: String]) {
        while asks.count > Self.linkQueueCap, let key = asks.keys.first { asks[key] = nil }
    }

    // MARK: - Sumi's peer tool

    /// `peer` with action list, send, ask or answer.
    func peerCommand(_ args: [String: Any], reply: @escaping (Result<String, PlanError>) -> Void) {
        let action = (args["action"] as? String) ?? "list"
        guard action != "list" else { return reply(.success(describeLink())) }
        guard link.settings.enabled else {
            return reply(.failure(PlanError("Tako Link is off; the user turns it on in Settings › Link")))
        }
        switch outgoing(action, args) {
        case .failure(let error): reply(.failure(error))
        case .success(let (message, peer)):
            if sumi?.turnFromUser == true {
                sendLink(message, to: peer) { error in
                    reply(error.map { .failure(PlanError("not sent: \($0)")) } ?? .success("sent to \(peer.name)" + (message.kind == .ask
                        ? " (request \(message.id)); their answer arrives as a peer message" : "")))
                }
            } else {
                requestApproval(message, to: peer)
                reply(.success("awaiting the user's approval: Tako shows them the exact text to Send, Edit or Deny, and "
                    + "you'll hear what they decide. Don't send it again"))
            }
        }
    }

    /// The message an action means, after every check that doesn't depend on whose turn it is.
    private func outgoing(_ action: String, _ args: [String: Any]) -> Result<(LinkMessage, TakoLink.Peer), PlanError> {
        let kind: LinkMessage.Kind
        var peer: TakoLink.Peer?
        var requestID: String?
        var text = args["text"] as? String
        switch action {
        case "send", "ask":
            kind = action == "ask" ? .ask : .chat
            if kind == .ask { text = (args["question"] as? String) ?? text }
            guard let name = args["peer"] as? String, !name.isEmpty else { return .failure(PlanError("\(action) needs peer")) }
            peer = link.peer(named: name)
            guard peer != nil else { return .failure(PlanError("no paired peer named \(name); \(pairedNames)")) }
        case "answer":
            kind = .answer
            guard let id = args["request_id"] as? String, !id.isEmpty else { return .failure(PlanError("answer needs request_id")) }
            guard let fingerprint = link.openAsks[id], let asker = link.peer(fingerprint: fingerprint) else {
                return .failure(PlanError("no open ask \(id); peer list shows the asks waiting for you"))
            }
            peer = asker
            requestID = id
        default:
            return .failure(PlanError("action must be list, send, ask or answer"))
        }
        let body = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return .failure(PlanError("\(action) needs \(kind == .ask ? "question" : "text")")) }
        guard body.utf8.count <= LinkLimits.maxText else { return .failure(PlanError("too long: keep it under 32 KB")) }
        if let secret = SecretScan.reason(body) {
            return .failure(PlanError("blocked: it looks like it contains \(secret). Never send secrets to a peer; rewrite it without"))
        }
        let message = LinkMessage(kind: kind, id: LinkMessage.newID(kind == .ask ? "q" : "m"), text: body, requestID: requestID)
        return .success((message, peer!))
    }

    private var pairedNames: String {
        link.peers.isEmpty ? "none are paired yet (Settings › Link)" : "paired: " + link.peers.map(\.name).joined(separator: ", ")
    }

    /// Sends, then keeps the books: the dock's history, and which asks are open.
    func sendLink(_ message: LinkMessage, to peer: TakoLink.Peer, completion: @escaping (String?) -> Void) {
        link.send(message, to: peer) { [weak self] error in
            guard let self else { return }
            if error == nil {
                switch message.kind {
                case .ask:
                    self.link.sentAsks[message.id] = peer.fingerprint
                    self.trim(&self.link.sentAsks)
                case .answer: if let request = message.requestID { self.link.openAsks[request] = nil }
                default: break
                }
                self.remember(LinkInboxItem(id: message.id, peerName: peer.name, kind: message.kind, text: message.text ?? "",
                                            requestID: message.kind == .ask ? message.id : message.requestID, incoming: false))
            }
            completion(error)
        }
    }

    private func requestApproval(_ message: LinkMessage, to peer: TakoLink.Peer) {
        link.approvals.append(LinkApproval(id: message.id, peer: peer, message: message))
        EventLog.record("link", "awaiting approval: \(message.kind.rawValue) to \(peer.name)",
                        fields: ["peer": peer.name, "message": message.kind.rawValue, "bytes": message.text?.utf8.count ?? 0])
        guard notifiesUser else { return }
        let verb = message.kind == .ask ? "ask" : message.kind == .answer ? "answer" : "write to"
        notifier.postLink(identifier: "approval-" + message.id, title: "Sumi wants to \(verb) \(peer.name)",
                          body: String((message.text ?? "").prefix(200)))
    }

    // MARK: - The user's decision

    /// Send (with `text` when the user edited it). Nil once on its way, else why it can't go.
    @discardableResult
    func approveLink(_ id: String, text edited: String? = nil) -> String? {
        guard let index = link.approvals.firstIndex(where: { $0.id == id }) else { return "nothing waiting with id \(id)" }
        var approval = link.approvals[index]
        if let edited {
            let body = edited.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return "the message is empty" }
            if let secret = SecretScan.reason(body) { return "it looks like it contains \(secret); remove it first" }
            approval.message.text = body
        }
        link.approvals.remove(at: index)
        let peer = approval.peer
        sendLink(approval.message, to: peer) { [weak self] error in
            let what = approval.message.kind == .answer ? "answer" : approval.message.kind == .ask ? "ask" : "message"
            let receipt = error.map { "Tako Link: the user approved your \(what) to \(peer.name), but it wasn't sent: \($0)" }
                ?? "Tako Link: the user approved your \(what) to \(peer.name)\(edited == nil ? "" : " (with edits)"); it was sent"
            self?.addToSumiDigest(SumiEvent(label: "link", kind: .messageReceipt(receipt)))
        }
        return nil
    }

    func denyLink(_ id: String) {
        guard let index = link.approvals.firstIndex(where: { $0.id == id }) else { return }
        let approval = link.approvals.remove(at: index)
        EventLog.record("link", "denied: \(approval.message.kind.rawValue) to \(approval.peer.name)",
                        fields: ["peer": approval.peer.name, "message": approval.message.kind.rawValue])
        addToSumiDigest(SumiEvent(label: "link", kind: .messageReceipt(
            "Tako Link: the user denied your \(approval.message.kind.rawValue) to \(approval.peer.name); it wasn't sent. Don't retry unless they ask")))
    }

    // MARK: - Describing

    /// `peer list`: who's paired and online, and what's waiting.
    func describeLink() -> String {
        guard link.settings.enabled else {
            return "Tako Link is off. The user turns it on in Settings › Link (\"let Tako on this network find you\")."
        }
        var lines = ["Tako Link is on as \(link.displayName)."]
        if link.peers.isEmpty {
            lines.append("No paired peers yet: the user pairs from Settings › Link.")
        } else {
            lines.append("Paired peers:")
            lines += link.peers.map { "- \($0.name): \(link.isOnline($0) ? "online" : "offline")" }
        }
        let asks = link.inbox.filter { $0.incoming && $0.kind == .ask && link.openAsks[$0.id] != nil }
        if !asks.isEmpty {
            lines.append("Asks waiting for your answer:")
            lines += asks.map { "- request_id \($0.id) from \($0.peerName): \(String($0.text.prefix(120)))" }
        }
        if !link.approvals.isEmpty { lines.append("\(link.approvals.count) message(s) waiting for the user's approval.") }
        return lines.joined(separator: "\n")
    }
}
