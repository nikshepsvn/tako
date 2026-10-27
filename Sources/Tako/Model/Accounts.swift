import Foundation

/// A Claude Code or Codex sign-in. Each extra account runs from its own config root
/// (`CLAUDE_CONFIG_DIR` / `CODEX_HOME`), the way both CLIs isolate accounts natively: its own
/// login, settings copy, and conversation history. "default" is the CLI's own root (`~/.claude`,
/// `~/.codex`) and is never overridden, since pointing Claude at ~/.claude explicitly would
/// create a second, separate sign-in.
struct AgentAccount: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var kind: SessionKind
    var name: String

    static let defaultID = "default"
    var isDefault: Bool { id == Self.defaultID }

    /// The config root it runs with; nil for the default account.
    var directory: URL? {
        isDefault ? nil : AccountStore.root.appendingPathComponent("\(kind.rawValue)/\(id)", isDirectory: true)
    }

    /// The CLI's own root, where the default account and shared settings live.
    var homeDirectory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return directory ?? home.appendingPathComponent(kind.adapter?.homeFolder ?? ".claude", isDirectory: true)
    }

    /// Environment an agent on this account runs with.
    var environment: [String: String] {
        guard let directory, let adapter = kind.adapter else { return [:] }
        return [adapter.homeVariable: directory.path]
    }
}

@MainActor
final class AccountStore: ObservableObject {
    static let shared = AccountStore()
    nonisolated static var root: URL { ControlPaths.supportDirectory.appendingPathComponent("accounts", isDirectory: true) }
    private static var registry: URL { root.appendingPathComponent("accounts.json") }

    /// Extra accounts (defaults are implicit).
    @Published private(set) var custom: [AgentAccount] = []

    private init() {
        if let data = try? Data(contentsOf: Self.registry),
           let saved = try? JSONDecoder().decode([AgentAccount].self, from: data) {
            custom = saved
        }
    }

    func accounts(for kind: SessionKind) -> [AgentAccount] {
        guard kind.isAgent else { return [] }
        return [AgentAccount(id: AgentAccount.defaultID, kind: kind, name: "Default")] + custom.filter { $0.kind == kind }
    }

    func account(_ id: String?, kind: SessionKind) -> AgentAccount? {
        accounts(for: kind).first { $0.id == (id ?? AgentAccount.defaultID) }
    }

    /// Which account new agents of this kind start on.
    func preferredID(for kind: SessionKind) -> String {
        let id = UserDefaults.standard.string(forKey: "preferredAccount.\(kind.rawValue)") ?? AgentAccount.defaultID
        return account(id, kind: kind) == nil ? AgentAccount.defaultID : id
    }

    func setPreferred(_ account: AgentAccount) {
        UserDefaults.standard.set(account.id, forKey: "preferredAccount.\(account.kind.rawValue)")
        objectWillChange.send()
    }

    // MARK: - Adding and removing

    @discardableResult
    func add(kind: SessionKind, name raw: String) -> AgentAccount? {
        let name = raw.trimmingCharacters(in: .whitespaces)
        let slug = normalizeLabel(name)
        guard kind.isAgent, !slug.isEmpty, slug != AgentAccount.defaultID, account(slug, kind: kind) == nil else { return nil }
        let account = AgentAccount(id: slug, kind: kind, name: name)
        guard let directory = account.directory else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Self.seed(account)
        custom.append(account)
        save()
        return account
    }

    /// Removes the account from Tako. Its folder (and so its sign-in and history) stays on
    /// disk; deleting someone's credentials should never be one click.
    func remove(_ account: AgentAccount) {
        custom.removeAll { $0.id == account.id && $0.kind == account.kind }
        if preferredID(for: account.kind) == account.id {
            UserDefaults.standard.removeObject(forKey: "preferredAccount.\(account.kind.rawValue)")
        }
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(custom).write(to: Self.registry, options: .atomic)
    }

    /// A new account starts with your settings, skills, and MCP servers, never your sign-in:
    /// shared pieces are linked to the default root, and identity files are left out.
    private static func seed(_ account: AgentAccount) {
        guard let directory = account.directory else { return }
        let home = AgentAccount(id: AgentAccount.defaultID, kind: account.kind, name: "Default").homeDirectory
        account.kind.adapter?.seed(directory, from: home)
    }

    nonisolated static func link(_ name: String, from source: URL, into directory: URL) {
        let target = source.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        try? FileManager.default.createSymbolicLink(at: directory.appendingPathComponent(name), withDestinationURL: target)
    }

    // MARK: - Identity

    /// The email an account is signed in as, read from the CLI's own files; nil when signed out.
    nonisolated static func signedInEmail(_ account: AgentAccount) -> String? {
        account.kind.adapter?.signedInEmail(home: account.homeDirectory, isDefault: account.isDefault)
    }

    nonisolated static func jwtEmail(_ token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count > 1 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return claims["email"] as? String
    }

    // MARK: - Moving a conversation

    /// Copies one conversation from one account's history into another's, so an agent can move
    /// to a different account (say, after a rate limit) and resume where it was.
    nonisolated static func copyConversation(_ sessionID: String, from source: AgentAccount, to destination: AgentAccount) -> Bool {
        let history = source.kind.adapter?.historyFolder ?? "projects"
        return copyConversation(sessionID, from: source.homeDirectory.appendingPathComponent(history),
                                to: destination.homeDirectory.appendingPathComponent(history))
    }

    /// Copies every transcript naming `sessionID` under `sourceRoot` to the same relative path
    /// under `destinationRoot`.
    nonisolated static func copyConversation(_ sessionID: String, from sourceRoot: URL, to destinationRoot: URL) -> Bool {
        let fm = FileManager.default
        // The walker yields resolved paths (/private/var, a symlinked ~/.claude), so the root must
        // be resolved too before cutting it off.
        let root = sourceRoot.resolvingSymlinksInPath().path
        guard let walker = fm.enumerator(at: sourceRoot, includingPropertiesForKeys: nil) else { return false }
        var copied = false
        for case let file as URL in walker where file.pathExtension == "jsonl" && file.lastPathComponent.contains(sessionID) {
            let path = file.resolvingSymlinksInPath().path
            guard path.hasPrefix(root) else { continue }
            let relative = String(path.dropFirst(root.count))
            let target = URL(fileURLWithPath: destinationRoot.path + relative)
            try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: target)
            if (try? fm.copyItem(at: file, to: target)) != nil { copied = true }
        }
        return copied
    }
}
