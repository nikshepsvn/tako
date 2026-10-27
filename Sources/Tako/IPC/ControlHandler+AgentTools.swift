import Foundation

/// A value, or the reply that refuses it.
enum Checked<Value> {
    case success(Value)
    case failure(ControlResponse)
}

/// The worker agents' coordination tools: wait_for, agent_changes, team_board, server_logs and
/// notify_user. Waiting, reading changes and reading logs are reads, so they follow read's rules
/// (anyone, but only the user reads shells). Posting, claiming and notifying act as the caller,
/// so they need an agent terminal to act as.
extension ControlHandler {
    static let defaultClaimMinutes = 120
    static let maxClaimPaths = 20

    /// list_terminals rows, with the files each agent claimed.
    func listedInfo(_ session: TerminalSession) -> SessionInfo {
        var info = session.info()
        info.claims = store.claims(of: session)
        return info
    }

    /// A terminal an agent may read: anything but a shell, which only the user reads.
    private func readable(_ name: String?) -> Checked<TerminalSession> {
        guard let target = resolve(name) else { return .failure(notFound(name)) }
        if !isUser, target.kind == .shell, target.id != callerSession?.id {
            return .failure(.failure("@\(target.label) is a shell; agents can't read shells"))
        }
        if target.kind == .browser { return .failure(.failure("@\(target.label) is a browser; use the browser tools")) }
        return .success(target)
    }

    // MARK: - wait_for

    func waitFor(_ request: ControlRequest, reply: @escaping ControlServer.Reply) {
        let target: TerminalSession
        switch readable(request.target) {
        case .success(let session): target = session
        case .failure(let response): reply(response); return
        }
        if target.id == callerSession?.id { reply(.failure("that's you; wait on another terminal")); return }
        let timeout = TimeInterval(max(1, min(request.timeout ?? agentWaitDefault, agentWaitMax)))
        if let pattern = request.pattern, !pattern.isEmpty {
            guard let regex = LogTail.regex(pattern) else { reply(.failure("pattern is empty")); return }
            store.startWait(on: target, caller: callerSession?.id, goal: .output, regex: regex, timeout: timeout, reply: reply)
            return
        }
        guard let goal = AgentWait.Goal(rawValue: request.text ?? "done"), goal != .output else {
            reply(.failure("until must be done, needs-input or exited (or pass a pattern)"))
            return
        }
        if !target.kind.isAgent, goal == .needsInput {
            reply(.failure("@\(target.label) is a \(target.kind.displayName.lowercased()); only agents wait for input"))
            return
        }
        store.startWait(on: target, caller: callerSession?.id, goal: goal, regex: nil, timeout: timeout, reply: reply)
    }

    // MARK: - agent_changes

    /// Git runs off the main thread; the report comes back as one block of text.
    func changes(_ request: ControlRequest, reply: @escaping ControlServer.Reply) {
        let target: TerminalSession
        if request.target?.isEmpty ?? true {
            guard let me = callerAgent else { reply(.failure("say whose changes")); return }
            target = me
        } else {
            switch readable(request.target) {
            case .success(let session): target = session
            case .failure(let response): reply(response); return
            }
        }
        guard target.kind.isAgent else {
            reply(.failure("@\(target.label) is a \(target.kind.displayName.lowercased()), not an agent with a workspace"))
            return
        }
        let root = store.workspaceRoot(of: target)
        let paths = (request.paths ?? []).compactMap { ClaimPath.normalize($0, root: root) }
        let (path, base, label) = (target.spec.workPath, target.spec.baseBranch, target.label)
        let uncommitted = request.text == "uncommitted", patch = request.flag == true
        DispatchQueue.global(qos: .userInitiated).async {
            let report = AgentChanges.report(at: path, base: base, uncommitted: uncommitted, patch: patch, paths: paths)
            reply(.success(text: "@\(label): " + report))
        }
    }

    // MARK: - team_board

    func board(_ request: ControlRequest) -> ControlResponse {
        let action = request.text ?? "read"
        if action == "read", isUser, let target = resolve(request.target) {
            return .success(text: store.readBoard(for: target, since: Int(request.since ?? "") ?? 0))
        }
        guard let agent = callerAgent else { return .failure("the team board works from inside an agent terminal") }
        switch action {
        case "read":
            return .success(text: store.readBoard(for: agent, since: Int(request.since ?? "") ?? 0))
        case "note":
            let text = sanitizeMessage(request.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return .failure("a note needs text") }
            return .success(text: store.postNote(String(text.prefix(1000)), by: agent))
        case "claim":
            switch claimPaths(request.paths, for: agent) {
            case .success(let paths):
                let minutes = max(5, min(request.timeout ?? Self.defaultClaimMinutes, 1440))
                return .success(text: store.claimFiles(paths, by: agent, minutes: minutes))
            case .failure(let response):
                return response
            }
        case "release":
            guard let raw = request.paths, !raw.isEmpty else { return .success(text: store.releaseFiles(nil, by: agent)) }
            switch claimPaths(raw, for: agent) {
            case .success(let paths): return .success(text: store.releaseFiles(paths, by: agent))
            case .failure(let response): return response
            }
        default:
            return .failure("action must be read, note, claim or release")
        }
    }

    /// Claimed paths, relative to the project. Every path must make sense, or nothing is claimed.
    private func claimPaths(_ raw: [String]?, for agent: TerminalSession) -> Checked<[String]> {
        let raw = raw ?? []
        guard !raw.isEmpty else { return .failure(.failure("pass the paths to claim")) }
        guard raw.count <= Self.maxClaimPaths else { return .failure(.failure("claim at most \(Self.maxClaimPaths) paths at once; use a folder or a glob")) }
        let root = store.workspaceRoot(of: agent)
        var paths: [String] = []
        for path in raw {
            guard let normalized = ClaimPath.normalize(sanitizeMessage(path), root: root) else {
                return .failure(.failure("\(path) isn't a path inside your workspace"))
            }
            if !paths.contains(normalized) { paths.append(normalized) }
        }
        return .success(paths)
    }

    // MARK: - server_logs

    func logs(_ request: ControlRequest) -> ControlResponse {
        let target: TerminalSession
        switch readable(request.target) {
        case .success(let session): target = session
        case .failure(let response): return response
        }
        let limit = max(1, min(request.lines ?? 100, 500))
        let grep = request.pattern.flatMap { $0.isEmpty ? nil : $0 }
        let errorsOnly = request.flag == true
        let since = request.since.flatMap { $0.isEmpty ? nil : $0 }
        // Filters look over the whole scrollback Tako keeps; a plain tail reads only what it shows.
        let filtered = grep != nil || errorsOnly || since != nil
        let all = LogTail.lines(store.recentOutput(of: target, lines: filtered ? 2000 : limit))
        var lines = all
        var notes: [String] = []
        if let since {
            if let after = LogTail.after(since, in: all) {
                lines = after
            } else {
                notes.append("(cursor not found: the output scrolled past it or was cleared; showing everything kept)")
            }
        }
        if errorsOnly { lines = LogTail.errors(lines) }
        if let grep {
            guard let regex = LogTail.regex(grep) else { return .failure("grep is empty") }
            lines = lines.filter { LogTail.matches(regex, $0) }
        }
        let shown = lines.suffix(limit)
        if shown.count < lines.count { notes.append("(\(lines.count - shown.count) earlier matching lines left out)") }
        let body = shown.isEmpty ? (filtered ? "(no matching lines)" : "(no output)") : shown.joined(separator: "\n")
        let state = "@\(target.label) is \(target.state.key)" + (target.state.detail.map { " (\($0))" } ?? "")
        return .success(text: (notes + [body, "── \(state) · cursor \(LogTail.cursor(all)) (pass as since for newer lines) ──"]).joined(separator: "\n"))
    }

    // MARK: - notify_user

    func notifyUser(_ request: ControlRequest) -> ControlResponse {
        guard let agent = callerAgent else { return .failure("notify_user works from inside an agent terminal") }
        let text = sanitizeMessage(request.text ?? "").split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return .failure("say what the user should know") }
        switch store.notifyUser(String(text.prefix(200)), from: agent) {
        case .success(let reply): return .success(text: reply)
        case .failure(let error): return .failure(error.description)
        }
    }
}
