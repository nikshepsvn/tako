import Foundation

/// Codex's app-server, private to one Codex session. The wrapper starts it on a loopback port
/// behind a capability token and attaches Codex's TUI to it with `--remote`, so Codex still runs
/// in its terminal; Tako joins as a second JSON-RPC client. Every client following a thread gets
/// its approval requests, the first answer wins, and the server tells the others
/// (`serverRequest/resolved`): answering in Tako closes the terminal's dialog, and answering in
/// the terminal closes Tako's. Requests Tako doesn't map (questions, MCP elicitations, network
/// permissions) are left to the TUI. Verified live against codex-cli 0.160.1.
@MainActor
final class CodexAppServer {
    /// The hook source the wrapper reports the server under, and the approvals' source.
    static let source = "codex-app-server"

    /// A JSON-RPC id, which may be a number or a string.
    enum RequestID: Hashable {
        case number(Int)
        case text(String)

        init?(_ value: Any?) {
            if let number = value as? Int { self = .number(number) } else if let text = value as? String { self = .text(text) } else { return nil }
        }

        var json: Any {
            switch self {
            case .number(let number): return number
            case .text(let text): return text
            }
        }
    }

    /// A command or file change waiting on approval, from `item/commandExecution/requestApproval`
    /// or `item/fileChange/requestApproval`.
    struct Approval {
        enum Kind: Equatable { case command, fileChange }
        let id: RequestID
        let threadID: String
        let itemID: String?
        let kind: Kind
        /// The command as the agent wrote it, without Codex's `/bin/zsh -lc '…'` around it.
        let command: String?
        let cwd: String?
        let reason: String?
        /// Paths the change touches, when its item was seen starting.
        var paths: [String] = []
        /// The decisions Codex offers, as sent: "accept", "acceptForSession", "decline", "cancel",
        /// or an object (`acceptWithExecpolicyAmendment`). Nil means the request's defaults.
        let available: [Any]?

        /// The same request as a PermissionRequest hook payload, so it takes the hook's path through
        /// Tako (needs-you, banners, Sumi's guard, Phone Mode).
        var hookPayload: [String: Any] {
            var payload: [String: Any] = ["hook_event_name": "PermissionRequest", "session_id": threadID]
            if let cwd { payload["cwd"] = cwd }
            switch kind {
            case .command:
                payload["tool_name"] = "Bash"
                var input: [String: Any] = ["command": command ?? ""]
                if let reason { input["description"] = reason }
                payload["tool_input"] = input
            case .fileChange:
                payload["tool_name"] = "Edit"
                payload["tool_input"] = paths.first.map { ["file_path": $0] } ?? [:]
            }
            if let always = alwaysDecision { payload["permission_suggestions"] = [["type": "codexDecision", "decision": always]] }
            return payload
        }

        /// What "always" means here: this session, or Codex's proposed rule for commands like it.
        var alwaysDecision: Any? {
            guard let available else { return kind == .fileChange ? "acceptForSession" : nil }
            if available.contains(where: { $0 as? String == "acceptForSession" }) { return "acceptForSession" }
            return available.first { ($0 as? [String: Any])?["acceptWithExecpolicyAmendment"] != nil }
        }

        /// The decision Codex takes for a hook-shaped reply: allow → accept, allow with Tako's
        /// "always" suggestion → that decision, deny → decline (or cancel when decline isn't
        /// offered). Nil (no decision) leaves the request to the terminal.
        func decision(hookOutput: String?) -> Any? {
            guard let hookOutput, let data = hookOutput.data(using: .utf8),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let decision = (json["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any],
                  let behavior = decision["behavior"] as? String else { return nil }
            switch behavior {
            case "allow":
                let suggestion = (decision["updatedPermissions"] as? [[String: Any]])?.first { $0["type"] as? String == "codexDecision" }
                return suggestion?["decision"] ?? "accept"
            case "deny":
                let offersDecline = available.map { $0.contains { $0 as? String == "decline" } } ?? true
                return offersDecline ? "decline" : "cancel"
            default:
                return nil
            }
        }
    }

    /// One message from the server, as far as Tako cares.
    enum Message {
        case approval(Approval)
        /// A request was answered, by any client.
        case resolved(RequestID)
        /// A conversation started (not an ephemeral helper or a subagent's).
        case threadStarted(String)
        /// A thread's status changed (a turn started or ended, an approval is waiting).
        case threadStatus(String)
        /// The reply to one of Tako's requests.
        case response(id: Int, succeeded: Bool)
        /// A file change item started, with the paths it touches.
        case fileChange(itemID: String, paths: [String])
        case other
    }

    static func parse(_ data: Data) -> Message {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .other }
        guard let method = json["method"] as? String else {
            guard let id = json["id"] as? Int else { return .other }
            return .response(id: id, succeeded: json["error"] == nil)
        }
        let params = json["params"] as? [String: Any] ?? [:]
        switch method {
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
            guard let id = RequestID(json["id"]), let thread = params["threadId"] as? String else { return .other }
            let command = method == "item/commandExecution/requestApproval"
            return .approval(Approval(id: id, threadID: thread, itemID: params["itemId"] as? String, kind: command ? .command : .fileChange,
                                      command: (params["command"] as? String).map(unwrapShell),
                                      cwd: params["cwd"] as? String,
                                      reason: params["reason"] as? String,
                                      paths: (params["grantRoot"] as? String).map { [$0] } ?? [],
                                      available: params["availableDecisions"] as? [Any]))
        case "serverRequest/resolved":
            return RequestID(params["requestId"]).map(Message.resolved) ?? .other
        case "thread/started":
            guard let thread = params["thread"] as? [String: Any], let id = thread["id"] as? String,
                  thread["ephemeral"] as? Bool != true, thread["parentThreadId"] is NSNull || thread["parentThreadId"] == nil else { return .other }
            return .threadStarted(id)
        case "thread/status/changed":
            return (params["threadId"] as? String).map(Message.threadStatus) ?? .other
        case "item/started":
            guard let item = params["item"] as? [String: Any], item["type"] as? String == "fileChange",
                  let id = item["id"] as? String else { return .other }
            let paths = (item["changes"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
            return .fileChange(itemID: id, paths: paths)
        default:
            return .other
        }
    }

    /// `/bin/zsh -lc 'touch x.txt'` → `touch x.txt`; anything else as it is.
    static func unwrapShell(_ command: String) -> String {
        for shell in ["/bin/zsh -lc '", "/bin/bash -lc '", "/bin/sh -lc '", "zsh -lc '", "bash -lc '"]
        where command.hasPrefix(shell) && command.hasSuffix("'") && command.count > shell.count {
            return String(command.dropFirst(shell.count).dropLast()).replacingOccurrences(of: #"'\''"#, with: "'")
        }
        return command
    }

    // MARK: - Connection

    /// Called with each approval request for a followed thread.
    var onApproval: ((Approval) -> Void)?
    var onResolved: ((RequestID) -> Void)?
    /// The connection ended (the session's Codex quit, or the server went away).
    var onClose: (() -> Void)?

    private let task: URLSessionWebSocketTask
    private var nextID = 1
    /// Threads whose events reach Tako, and those being asked for (by request id).
    private var followed: Set<String> = []
    private var resuming: [Int: String] = [:]
    /// Threads seen starting or named by a hook, followed or not yet.
    private var known: Set<String> = []
    private var fileChanges: [String: [String]] = [:]
    private var closed = false

    /// Whether a thread's approvals reach Tako here.
    func follows(_ thread: String?) -> Bool { !closed && thread.map(followed.contains) == true }

    init(url: URL, token: String) {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        task = URLSession.shared.webSocketTask(with: request)
    }

    func connect() {
        task.resume()
        send(method: "initialize", params: ["clientInfo": ["name": "tako", "title": "Tako", "version": "1"],
                                            "capabilities": ["experimentalApi": true, "requestAttestation": false]])
        send(["jsonrpc": "2.0", "method": "initialized"])
        receive()
    }

    /// Subscribes to a conversation's events. The server replays requests already waiting, so
    /// following late still catches the one on screen. A brand-new thread can't be followed until
    /// its rollout exists (the server answers "no rollout found"), so a refusal is retried when
    /// the thread next changes status or a hook names it.
    func follow(_ thread: String) {
        guard !closed, isSafeIdentifier(thread), !followed.contains(thread), !resuming.values.contains(thread) else { return }
        known.insert(thread)
        resuming[nextID] = thread
        send(method: "thread/resume", params: ["threadId": thread, "excludeTurns": true])
    }

    func respond(_ id: RequestID, result: [String: Any]) {
        send(["jsonrpc": "2.0", "id": id.json, "result": result])
    }

    func close() {
        guard !closed else { return }
        closed = true
        task.cancel(with: .normalClosure, reason: nil)
        onClose?()
    }

    private func send(method: String, params: [String: Any]) {
        send(["jsonrpc": "2.0", "id": nextID, "method": method, "params": params])
        nextID += 1
    }

    private func send(_ message: [String: Any]) {
        guard !closed, let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        task.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
    }

    private func receive() {
        task.receive { [weak self] result in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !self.closed else { return }
                    switch result {
                    case .success(.string(let text)): self.handle(Data(text.utf8))
                    case .success(.data(let data)): self.handle(data)
                    case .success: break
                    case .failure: return self.close()
                    }
                    self.receive()
                }
            }
        }
    }

    /// Applies one message from the server.
    func handle(_ data: Data) {
        switch Self.parse(data) {
        case .approval(var approval):
            guard followed.contains(approval.threadID) else { return }
            if approval.kind == .fileChange, approval.paths.isEmpty, let item = approval.itemID {
                approval.paths = fileChanges[item] ?? []
            }
            onApproval?(approval)
        case .resolved(let id):
            onResolved?(id)
        case .threadStarted(let thread):
            follow(thread)
        case .threadStatus(let thread):
            if known.contains(thread) { follow(thread) }
        case .response(let id, let succeeded):
            guard let thread = resuming.removeValue(forKey: id) else { return }
            if succeeded { followed.insert(thread) }
        case .fileChange(let itemID, let paths):
            fileChanges[itemID] = paths
            if fileChanges.count > 50 { fileChanges.removeAll() }
        case .other:
            break
        }
    }
}
