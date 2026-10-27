import Foundation

/// Claude channels only load servers from the user's own Claude config, where turning channels on
/// used to register Tako as `hyperterm`. The server is `tako` now and the wrapper asks for
/// `server:tako`, so users who had channels on are re-registered once, at launch.
enum ChannelsMigration {
    static let doneKey = "channelsServerRenamedToTako"

    /// Removing `tako` first makes a retry after a half-finished run succeed instead of failing
    /// on "already exists". Removals that find nothing fail harmlessly; only the add decides.
    static func command(htPath: String) -> String {
        "claude mcp remove --scope user hyperterm >/dev/null 2>&1; "
            + "claude mcp remove --scope user tako >/dev/null 2>&1; "
            + "claude mcp add --scope user tako \(shellQuote(htPath)) mcp"
    }

    /// Runs off the main thread through a login shell, as turning channels on does. The flag is
    /// only set on success, so a failure (no `claude` on PATH yet) is retried next launch.
    @MainActor @discardableResult
    static func runIfNeeded(defaults: UserDefaults = .standard,
                            channelsEnabled: Bool = SessionStore.channelsEnabled,
                            htPath: String = AgentIntegration.htPath,
                            run: @escaping @Sendable (String) -> String? = { runProcess("/bin/zsh", ["-lic", $0], timeout: 30) }) async -> Bool {
        guard channelsEnabled, !defaults.bool(forKey: doneKey) else { return false }
        let command = command(htPath: htPath)
        let output = await Task.detached(priority: .utility) { run(command) }.value
        guard output != nil else {
            NSLog("tako: couldn't re-register the channels server as tako; will retry next launch")
            return false
        }
        defaults.set(true, forKey: doneKey)
        NSLog("tako: re-registered the channels server as tako in Claude's user config")
        return true
    }
}
