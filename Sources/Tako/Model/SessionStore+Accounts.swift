import Foundation

/// Agents are pinned to the account they started on. Moving one copies its conversation into the
/// other account's history and restarts it there, resuming where it was: the way out of a rate
/// limit without losing the thread.
extension SessionStore {
    @discardableResult
    func move(_ session: TerminalSession, to account: AgentAccount) -> Bool {
        guard session.kind.isAgent, account.kind == session.kind else { return false }
        let accounts = AccountStore.shared
        let current = accounts.account(session.spec.account, kind: session.kind)
            ?? accounts.accounts(for: session.kind)[0]
        guard current.id != account.id else { return false }
        var carried = false
        if let conversation = session.spec.agentSessionId {
            carried = AccountStore.copyConversation(conversation, from: current, to: account)
        }
        session.spec.account = account.isDefault ? nil : account.id
        persist()
        session.record(.note, "Moved to the \(account.name) account" + (carried ? ", conversation carried over" : ""))
        session.restart()
        return true
    }

    /// Opens a terminal that signs an account in with the CLI's own login flow.
    func signIn(_ account: AgentAccount) {
        var spec = LaunchSpec(label: "\(account.kind.rawValue)-\(account.id)-login", kind: .shell,
                              cwd: NSHomeDirectory(), command: account.kind.adapter?.signInCommand)
        spec.labelSource = .auto
        spec.account = account.isDefault ? nil : account.id
        spec.accountKind = account.kind
        create(spec)
    }
}
