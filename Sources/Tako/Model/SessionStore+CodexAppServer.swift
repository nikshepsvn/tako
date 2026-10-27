import Foundation

/// Codex sessions behind their own app-server (see `CodexAppServer`): approvals arrive as
/// JSON-RPC requests and are answered the same way, never with keystrokes. A Codex without one
/// keeps the PermissionRequest hook, and prompts without either fall back to keys.
extension SessionStore {
    /// The wrapper's report that this session's Codex is up behind an app-server: its loopback
    /// URL and the file holding the capability token.
    func attachCodexAppServer(_ session: TerminalSession, json: [String: Any]) {
        guard session.kind == .codex, let url = (json["url"] as? String).flatMap(URL.init(string:)),
              url.scheme == "ws", url.host == "127.0.0.1", url.port != nil,
              let tokenFile = json["token_file"] as? String,
              let token = try? String(contentsOfFile: tokenFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else { return }
        codexServers.removeValue(forKey: session.id)?.close()
        let server = CodexAppServer(url: url, token: token)
        server.onApproval = { [weak self, weak session, weak server] approval in
            guard let self, let session, let server else { return }
            self.registerCodexApproval(approval, for: session, server: server)
        }
        server.onResolved = { [weak self, weak session] id in
            guard let self, let session, let held = self.codexHeldRequests[session.id], held.request == id,
                  self.approvals[session.id]?.id == held.approval else { return }
            // Answered in the terminal: Tako's copy of the dialog goes.
            self.dropApproval(for: session)
        }
        server.onClose = { [weak self, weak session, weak server] in
            guard let self, let session, let server, self.codexServers[session.id] === server else { return }
            self.codexServers[session.id] = nil
            self.codexHeldRequests[session.id] = nil
        }
        codexServers[session.id] = server
        server.connect()
        session.record(.note, "Codex approvals come from its app-server")
    }

    /// A Codex hook names its thread: follow it, which also catches a resumed conversation that
    /// the server doesn't announce as started.
    func followCodexThread(_ session: TerminalSession, json: [String: Any]) {
        guard let thread = json["session_id"] as? String else { return }
        codexServers[session.id]?.follow(thread)
    }

    /// Whether this thread's approvals reach Tako over its app-server, so its PermissionRequest
    /// hook should step aside.
    func approvesOverAppServer(_ session: TerminalSession, thread: String?) -> Bool {
        codexServers[session.id]?.follows(thread) == true
    }

    /// Takes the request through the hook's path (needs-you, banner, Sumi, Phone Mode) with a
    /// reply that answers over JSON-RPC. No decision leaves the request to the terminal.
    private func registerCodexApproval(_ approval: CodexAppServer.Approval, for session: TerminalSession, server: CodexAppServer) {
        guard let data = try? JSONSerialization.data(withJSONObject: approval.hookPayload) else { return }
        registerApproval(for: session, source: CodexAppServer.source, payload: String(decoding: data, as: UTF8.self)) { [weak server] response in
            guard let decision = approval.decision(hookOutput: response.text) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { server?.respond(approval.id, result: ["decision": decision]) }
            }
        }
        if let held = approvals[session.id], held.source == CodexAppServer.source {
            codexHeldRequests[session.id] = (approval.id, held.id)
        }
    }
}
