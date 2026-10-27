import Foundation

/// When Sumi may act on terminals the user didn't hand it.
///
/// Sumi restarts, interrupts, picks options on and closes other agents only where the user
/// handed them over (handle_waiting) or in Phone Mode. "Just kill all of it and restart them"
/// is a direct order too, so `user_requested` lets Sumi act on any agent, under three checks:
///
/// 1. Only Sumi has these tools, and the kernel (`CallerIdentity`), not the request, says who
///    called: another agent can't send `user_requested` at all.
/// 2. Tako checks whose turn Sumi is acting in. A turn the user started with their own prompt
///    counts. One that began with another agent's message ("Message from @…"), a Tako digest
///    ("Tako: …", which quotes agents' summaries) or a channel event doesn't, so text an agent
///    wrote can't turn into an order by being repeated to Sumi.
/// 3. It widens who Sumi may act on, never what is allowed: risky permission menus still need
///    `user_approved` for that exact request, and a close still respects work at risk unless the
///    user also said to close it anyway (`force`).
///
/// What remains is the model's honesty within a user's turn; the tool descriptions say to pass
/// it only for what the user asked in their own words.
extension SessionStore {
    /// Nil when Sumi may act on `session` as the user asked; otherwise why not.
    func userRequestRefusal(_ userRequested: Bool) -> DelegationError? {
        guard userRequested else { return nil }
        guard sumi?.turnFromUser ?? false else {
            return DelegationError("user_requested counts only in a turn the user started; this one began with a message "
                + "from an agent or Tako. Ask the user, then act on their answer")
        }
        return nil
    }

    /// The labels a batch names: labels, "@duaa-*" style globs, or "all" (every agent but Sumi).
    /// Each matched session once, in the order named; names that match nothing come back apart.
    func sessions(matching names: [String]) -> (found: [TerminalSession], unknown: [String]) {
        var found: [TerminalSession] = []
        var unknown: [String] = []
        func add(_ session: TerminalSession) {
            if !found.contains(where: { $0.id == session.id }) { found.append(session) }
        }
        for raw in names {
            let name = raw.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            let pattern = name.hasPrefix("@") ? String(name.dropFirst()).lowercased() : name.lowercased()
            if pattern == "all" || pattern == "*" {
                orderedSessions.filter { $0.kind.isAgent && !$0.isSumi }.forEach(add)
            } else if pattern.contains("*") || pattern.contains("?") {
                let matches = orderedSessions.filter { !$0.isSumi && fnmatch(pattern, $0.label, 0) == 0 }
                if matches.isEmpty { unknown.append(raw) }
                matches.forEach(add)
            } else if let session = find(name) {
                add(session)
            } else {
                unknown.append(raw)
            }
        }
        return (found, unknown)
    }
}

/// A prompt the user typed themselves, as opposed to text Tako put in Sumi's prompt for others.
func isUsersOwnPrompt(_ prompt: String) -> Bool {
    let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    return !isAgentMessage(text) && !text.hasPrefix("Tako: ") && !text.hasPrefix("<channel")
}
