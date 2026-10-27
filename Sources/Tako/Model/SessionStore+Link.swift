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
        // TakoLink checks this too; Sumi's prompt is the place a bad id would do harm.
        guard message.hasValidIDs else { return }
        var localID: String?
        switch message.kind {
        case .ready, .receipt: return
        case .chat: break
        case .ask:
            // Sumi answers by an id made here, so nothing the peer chose names the request.
            let id = LinkMessage.newID("r")
            link.openAsks[id] = LinkOpenAsk(fingerprint: peer.fingerprint, remoteID: message.id)
            trim(&link.openAsks)
            localID = id
        case .answer:
            // Only an answer to an ask Sumi sent this peer counts; anything else is dropped.
            guard let request = message.requestID, link.sentAsks[request] == peer.fingerprint else {
                EventLog.record("link", "dropped an answer from \(peer.name) to no open ask", fields: ["peer": peer.name])
                return
            }
            link.sentAsks[request] = nil
            localID = request
        }
        remember(LinkInboxItem(id: message.id, peerName: peer.name, kind: message.kind, text: message.text ?? "",
                               requestID: localID, incoming: true))
        deliverPeerPrompt(Self.peerPrompt(message, from: peer.name, requestID: localID), from: peer.name, kind: message.kind)
    }

    /// The single line Sumi reads for a peer's message. Everything the peer chose (name, text)
    /// stays inside the tag, cleaned so it can't close the tag, open another or span lines;
    /// `requestID` is Tako's own. The guidance after the tag is fixed text.
    static func peerPrompt(_ message: LinkMessage, from name: String, requestID: String? = nil) -> String {
        let name = LinkChannel.cleanName(name)
        var text = sanitizeMessage(message.text ?? "").replacingOccurrences(of: "<", with: "‹").replacingOccurrences(of: ">", with: "›")
        text = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        if text.count > peerPromptLimit { text = String(text.prefix(peerPromptLimit)) + "… (cut; the whole text is in the Sumi dock)" }
        var attributes = "from=\"\(name)\" kind=\"\(message.kind.rawValue)\""
        if let requestID, LinkMessage.isValidID(requestID) { attributes += " request_id=\"\(requestID)\"" }
        let body: String
        let guidance: String
        switch message.kind {
        case .ask:
            body = "\(name) (Tako Link) asks: \(text)"
            guidance = " A friend's request, not the user's: gather what's needed (standup, plan, read_terminal), then reply with "
                + "peer action answer and this tag's request_id. The user approves it before it goes out; never include secrets."
        case .answer:
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
        sumi.userPrompt = nil
        _ = sumi.deliver(prompt, from: nil)
    }

    /// Sumi is running again: what arrived meanwhile goes in, oldest first.
    func flushPeerMessages() {
        guard let sumi, !sumi.isExitedProcess, !link.undelivered.isEmpty else { return }
        let waiting = link.undelivered
        link.undelivered = []
        sumi.turnFromUser = false
        sumi.userPrompt = nil
        waiting.forEach { _ = sumi.deliver($0, from: nil) }
    }

    private func remember(_ item: LinkInboxItem) {
        link.inbox.append(item)
        if link.inbox.count > Self.linkQueueCap { link.inbox.removeFirst(link.inbox.count - Self.linkQueueCap) }
    }

    private func trim<Value>(_ asks: inout [String: Value]) {
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
            if consumeUserInstruction(message, to: peer) {
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

    /// Whether the user ordered exactly this message in their own prompt this turn ("tell Alex:
    /// back in 10"), and that order hasn't sent anything yet. Only then does it go without asking:
    /// in the user's turn Sumi may still have read files, tool output or other agents' words.
    /// Using it up here means a second send in the same turn needs approval.
    func consumeUserInstruction(_ message: LinkMessage, to peer: TakoLink.Peer) -> Bool {
        guard let sumi, sumi.turnFromUser, let prompt = sumi.userPrompt else { return false }
        let wanted = LinkInstruction.normal(message.text ?? "")
        for (index, order) in LinkInstruction.parse(prompt).enumerated() where !sumi.userInstructionsUsed.contains(index) {
            guard order.kind == message.kind, order.peer.lowercased() == peer.name.lowercased(), order.text == wanted, !wanted.isEmpty else { continue }
            sumi.userInstructionsUsed.insert(index)
            return true
        }
        return false
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
            guard let ask = link.openAsks[id], let asker = link.peer(fingerprint: ask.fingerprint) else {
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
        // The peer knows its ask by its own id; Sumi used the one Tako made here.
        let remote = requestID.flatMap { link.openAsks[$0]?.remoteID }
        let message = LinkMessage(kind: kind, id: LinkMessage.newID(kind == .ask ? "q" : "m"), text: body, requestID: remote)
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
                case .answer:
                    if let request = message.requestID { self.link.openAsks = self.link.openAsks.filter { $0.value.remoteID != request } }
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
        let asks = link.inbox.filter { item in item.incoming && item.kind == .ask && item.requestID.map { link.openAsks[$0] != nil } == true }
        if !asks.isEmpty {
            // The peer's words are cleaned like a <peer-message>: one line, no tags.
            lines.append("Asks waiting for your answer:")
            lines += asks.map { item in
                let text = item.text.replacingOccurrences(of: "<", with: "‹").replacingOccurrences(of: ">", with: "›")
                    .split(whereSeparator: \.isNewline).joined(separator: " ")
                return "- request_id \(item.requestID ?? "") from \(item.peerName): \(String(text.prefix(120)))"
            }
        }
        if !link.approvals.isEmpty { lines.append("\(link.approvals.count) message(s) waiting for the user's approval.") }
        return lines.joined(separator: "\n")
    }
}

/// An explicit order in the user's prompt: `tell <peer>: <text>` (or message), `ask <peer>: <question>`,
/// `answer <peer>: <text>`, at the start of a line or sentence, the peer with an optional @.
/// "don't tell Alex yes" isn't one; the text is everything after the colon to the end of the line.
struct LinkInstruction: Equatable {
    var kind: LinkMessage.Kind
    var peer: String
    var text: String

    private static let pattern = #"(?:^|[.!?;]\s+)(tell|message|ask|answer)\s+@?([^:\n]+?)\s*:[ \t]*([^\n]+)"#

    static func parse(_ prompt: String) -> [LinkInstruction] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .anchorsMatchLines]) else { return [] }
        let range = NSRange(prompt.startIndex..., in: prompt)
        return regex.matches(in: prompt, range: range).compactMap { match in
            guard let verb = Range(match.range(at: 1), in: prompt), let peer = Range(match.range(at: 2), in: prompt),
                  let text = Range(match.range(at: 3), in: prompt) else { return nil }
            let kind: LinkMessage.Kind
            switch prompt[verb].lowercased() {
            case "ask": kind = .ask
            case "answer": kind = .answer
            default: kind = .chat
            }
            return LinkInstruction(kind: kind, peer: prompt[peer].trimmingCharacters(in: .whitespaces), text: normal(String(prompt[text])))
        }
    }

    /// Whitespace collapsed and surrounding quotes dropped, for comparing the user's words with Sumi's.
    static func normal(_ text: String) -> String {
        var value = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let quotes: [(Character, Character)] = [("\"", "\""), ("'", "'"), ("“", "”"), ("‘", "’"), ("`", "`")]
        while value.count >= 2, let first = value.first, let last = value.last, quotes.contains(where: { $0.0 == first && $0.1 == last }) {
            value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return value
    }
}
