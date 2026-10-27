import AppKit
import Foundation

/// Generates the files that wire Claude Code and Codex into Tako without touching the user's
/// own config: hooks and MCP are passed per launch (`claude --settings/--mcp-config`,
/// `codex -c ...`) through small wrapper scripts in ~/.hyperterm/bin.
enum AgentIntegration {
    static var root: URL { ControlPaths.supportDirectory }
    static var binDirectory: URL { root.appendingPathComponent("bin") }
    static var htPath: String { binDirectory.appendingPathComponent("ht").path }
    /// The hook listener's port this launch; nil sends every Claude hook through `ht hook`.
    nonisolated(unsafe) static var hookPort: UInt16?

    /// Idempotent; run at every launch because the app bundle (and its `ht`) can move.
    static func install() {
        let fm = FileManager.default
        try? fm.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        linkBundledCLI()
        for adapter in SessionKind.agentAdapters { adapter.install(hookPort: hookPort) }
    }

    private static func linkBundledCLI() {
        guard let bundled = Bundle.main.resourceURL?.appendingPathComponent("bin/ht").path,
              FileManager.default.fileExists(atPath: bundled) else { return }
        try? FileManager.default.removeItem(atPath: htPath)
        try? FileManager.default.createSymbolicLink(atPath: htPath, withDestinationPath: bundled)
    }

    // MARK: - Launch

    static func surfaceLaunch(for spec: LaunchSpec) -> SurfaceLaunch {
        var environment = [
            "HT_SESSION_ID": spec.id.uuidString,
            "HT_HOOK_TOKEN": HookServer.token(for: spec.id.uuidString),
            "HT_LABEL": spec.label,
            "HT_SOCKET": ControlPaths.socketPath,
        ]
        if spec.kind == .claude && SessionStore.channelsEnabled { environment["HT_CHANNELS"] = "1" }
        // MCP servers the user wants started with the agent rather than on first use.
        if let eager = UserDefaults.standard.stringArray(forKey: "mcpEager"), !eager.isEmpty {
            environment["HT_MCP_EAGER"] = eager.joined(separator: ",")
        }
        if let port = spec.port {
            environment["PORT"] = String(port)
            environment["HT_PORT"] = String(port)
        }
        environment.merge(PortSlots.environment(for: spec)) { current, _ in current }
        // The account's config root (CLAUDE_CONFIG_DIR / CODEX_HOME). A sign-in terminal for an
        // account is a shell carrying the same variables.
        if let id = spec.account {
            let kind = spec.kind.isAgent ? spec.kind : (spec.accountKind ?? .claude)
            environment.merge(MainActor.assumeIsolated { AccountStore.shared.account(id, kind: kind)?.environment ?? [:] }) { _, new in new }
        }
        return SurfaceLaunch(workingDirectory: expandTilde(spec.cwd), command: nil, environment: environment)
    }

    /// Agents and servers are typed into a real login shell so the user's PATH and rc files
    /// apply, the command shows in history, and the shell remains after the program exits.
    /// Everything Tako interpolates is shell-quoted; only the user's own server command and
    /// agent arguments (typed by the user, never by agents) are passed through as written.
    static func initialInput(for spec: LaunchSpec, resume: Bool, task: String? = nil) -> String? {
        let extra = spec.command.map { " " + $0 } ?? ""
        // `--` ends option parsing (Claude and Codex both honour it), so a task that looks like a
        // flag ("--dangerously-skip-permissions") stays the prompt. Adapters put it last.
        let prompt = task.flatMap { $0.isEmpty ? nil : " -- " + shellQuote($0) } ?? ""
        let options = (spec.options?.arguments(for: spec.kind) ?? []).map { " " + shellQuote($0) }.joined()
        if let adapter = spec.kind.adapter {
            return adapter.launchCommand(for: spec, resume: resume, options: options, extra: extra, prompt: prompt)
        }
        switch spec.kind {
        case .server, .shell:
            return spec.command.map { $0 + "\n" }
        case .browser, .claude, .codex:
            return nil
        }
    }

    // MARK: - Helpers

    static func json(_ object: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static func write(_ content: String, to url: URL) {
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }

    static func writeExecutable(_ content: String, to url: URL) {
        write(content, to: url)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}

func expandTilde(_ path: String) -> String {
    (path as NSString).expandingTildeInPath
}

/// "~/Code/hyperterm" stays; deeper paths keep the last two components: "…/app/web".
func shortPath(_ path: String) -> String {
    let abbreviated = abbreviateHome(path)
    let parts = abbreviated.split(separator: "/")
    guard parts.count > 3 else { return abbreviated }
    return "…/" + parts.suffix(2).joined(separator: "/")
}

/// Single-quotes for POSIX shells: 'it'\''s'.
func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

func abbreviateHome(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
}
