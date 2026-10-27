import Foundation

/// Claude Code: hooks POST to Tako's listener and MCP comes from `--settings`/`--mcp-config`
/// files the wrapper passes; the conversation id is chosen at launch.
struct ClaudeAdapter: AgentAdapter {
    let command = "claude"

    // MARK: - Launch

    func install(hookPort: UInt16?) {
        let root = AgentIntegration.root
        AgentIntegration.write(Self.settings(hookPort: hookPort), to: root.appendingPathComponent("claude-settings.json"))
        AgentIntegration.write(Self.mcpConfig(), to: root.appendingPathComponent("mcp.json"))
        AgentIntegration.writeExecutable(Self.wrapperScript(), to: AgentIntegration.binDirectory.appendingPathComponent(command))
    }

    /// Hooks POST to Tako's listener (HookServer); SessionStart only runs command hooks.
    static func settings(hookPort: UInt16?) -> String {
        let htPath = AgentIntegration.htPath
        let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "Notification",
                      "Stop", "StopFailure", "SessionEnd", "TaskCreated", "TaskCompleted", "SubagentStart", "SubagentStop"]
        let command: [String: Any] = ["type": "command", "command": "\(htPath) hook claude", "timeout": 5]
        func hook(_ event: String) -> [String: Any] {
            guard let hookPort, event != "SessionStart" else { return command }
            return ["type": "http", "url": "http://127.0.0.1:\(hookPort)\(HookServer.path)", "timeout": 5,
                    "headers": ["X-HT-Session": "$HT_SESSION_ID", "Authorization": "Bearer $HT_HOOK_TOKEN"],
                    "allowedEnvVars": ["HT_SESSION_ID", "HT_HOOK_TOKEN"]]
        }
        var hooks: [String: Any] = Dictionary(uniqueKeysWithValues: events.map { ($0, [["hooks": [hook($0)]]]) })
        // Held open until the user decides in Tako (or answers in the terminal).
        let permission: [String: Any] = ["type": "command", "command": "\(htPath) permission claude", "timeout": 600]
        hooks["PermissionRequest"] = [["matcher": "*", "hooks": [permission]]]
        // Read-only and self-describing tools are safe to run without a prompt; messaging other
        // agents and starting servers still ask.
        let allow = ["list_terminals", "read_terminal", "rename_terminal", "set_status"].map { "mcp__hyperterm__" + $0 }
            + browserReadOnlyTools.map { "mcp__browser__" + $0 }
        // statusLine feeds cost/context/rate limits to Tako, then prints the user's own
        // statusline unchanged (`ht statusline` runs it).
        let statusLine: [String: Any] = ["type": "command", "command": "\(htPath) statusline", "padding": 0]
        var settings: [String: Any] = ["hooks": hooks, "permissions": ["allow": allow], "statusLine": statusLine]
        if !AgentBrowser.agentsMayUseOutsideChrome {
            settings["enabledPlugins"] = Dictionary(uniqueKeysWithValues: duplicateBrowserPlugins().map { ($0, false) })
        }
        return AgentIntegration.json(settings)
    }

    /// Plugins that start their own Chrome automation server in every agent (one node process
    /// tree each), doing what Tako's `browser` server already does in Tako's browser. Turned off
    /// for agents Tako starts, as --no-chrome turns off Claude in Chrome; the user's own Claude
    /// sessions keep them.
    static let browserPluginNames: Set<String> = ["chrome-devtools-mcp", "playwright"]

    /// Always turned off, even when no settings file Tako reads enables it: a project's
    /// `.claude/settings.json` can, and the user may turn it on after the agent's settings were
    /// written. Turning off a plugin that isn't installed changes nothing.
    static let alwaysOffPlugins = ["chrome-devtools-mcp@claude-plugins-official"]

    /// Browser plugins to turn off: the official one, any installed from another marketplace, and
    /// any the user's settings enable.
    static func duplicateBrowserPlugins(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        let claude = home.appendingPathComponent(".claude")
        func object(_ file: String) -> [String: Any]? {
            guard let data = try? Data(contentsOf: claude.appendingPathComponent(file)) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        var keys = Set(alwaysOffPlugins)
        keys.formUnion(((object("plugins/installed_plugins.json")?["plugins"]) as? [String: Any] ?? [:]).keys)
        for file in ["settings.json", "settings.local.json"] {
            let enabled = object(file)?["enabledPlugins"] as? [String: Any] ?? [:]
            keys.formUnion(enabled.filter { ($0.value as? Bool) == true }.keys)
        }
        return keys.filter { browserPluginNames.contains(String($0.split(separator: "@").first ?? "")) }.sorted()
    }

    private static func mcpConfig() -> String {
        let htPath = AgentIntegration.htPath
        return AgentIntegration.json(["mcpServers": [
            "hyperterm": ["command": htPath, "args": ["mcp"]],
            "browser": ["command": htPath, "args": ["browser-mcp", String(AgentBrowser.preferredPort)]],
        ]])
    }

    /// Browser tools that only look: screenshots, page snapshots, console and network logs.
    /// Navigating, clicking, typing, and running scripts still ask.
    static let browserReadOnlyTools = [
        "list_pages", "take_snapshot", "take_screenshot", "list_console_messages", "get_console_message",
        "list_network_requests", "get_network_request", "get_css_styles", "wait_for",
    ]

    /// Strips our bin dir from PATH so `claude` resolves to the real binary, then adds Tako's
    /// hooks and MCP server. User hooks still run: `--settings` merges with user settings. The
    /// second --mcp-config replaces the user's stdio servers by name; plugin, claude.ai, http and
    /// .mcp.json servers load as usual.
    static func wrapperScript() -> String {
        """
        #!/bin/sh
        # Generated by Tako. Runs the real Claude Code with Tako hooks + MCP attached.
        \(AgentIntegration.wrapperPrelude)
        CHANNEL=""
        [ "$HT_CHANNELS" = "1" ] && CHANNEL="--dangerously-load-development-channels server:hyperterm"
        # The user's own stdio MCP servers, same names, started on first use (ht mcp-lazy).
        LAZY=$("$HT_DIR/bin/ht" mcp-lazy-config claude 2>/dev/null)
        # --no-chrome: agents here browse in Tako's own browser (the "browser" MCP server),
        # not the user's everyday Chrome through Claude in Chrome. --mcp-config is variadic
        # (<configs...>); the `=` form keeps it from swallowing a prompt typed after it.
        exec claude --settings "$HT_DIR/claude-settings.json" --mcp-config="$HT_DIR/mcp.json" ${LAZY:+--mcp-config="$LAZY"} \(AgentBrowser.agentsMayUseOutsideChrome ? "" : "--no-chrome ")$CHANNEL "$@"
        """
    }

    /// Whether Claude saved a conversation under this id. A variable so tests can stand in for it.
    nonisolated(unsafe) static var conversationExists: (LaunchSpec, String) -> Bool = hasConversation

    private static func hasConversation(_ spec: LaunchSpec, _ id: String) -> Bool {
        // Launches are typed on the main thread, where the account store lives.
        let account = Thread.isMainThread ? MainActor.assumeIsolated { AccountStore.shared.account(spec.account, kind: .claude) } : nil
        let root = (account ?? AgentAccount(id: AgentAccount.defaultID, kind: .claude, name: "Default")).homeDirectory
        return AgentTranscript.claudeFile(session: id, cwds: [spec.workPath, expandTilde(spec.cwd)], root: root) != nil
    }

    func launchCommand(for spec: LaunchSpec, resume: Bool, options: String, extra: String, prompt: String) -> String {
        var args = "--name \(shellQuote(spec.label))"
        var enter = ""
        // An id given up front has no conversation until the first message (say the agent quit
        // at the folder-trust prompt); resuming it fails, so it starts fresh under the same id.
        if resume, let id = spec.agentSessionId, isSafeIdentifier(id), Self.conversationExists(spec, id) {
            args += " --resume \(shellQuote(id))"
            // Claude finds the conversation from the repo root, but then works there: a worktree
            // agent would edit the main checkout. Resume from inside its worktree instead.
            if spec.worktreeName != nil, FileManager.default.fileExists(atPath: spec.workPath) {
                enter = "cd \(shellQuote(spec.workPath)) && "
            }
        } else if let parent = spec.forkOf, isSafeIdentifier(parent) {
            // A fork continues the parent's conversation under a new session id; the parent
            // is untouched. Claude finds conversations by folder, so a fork starts in the
            // parent's own working folder.
            args += " --resume \(shellQuote(parent)) --fork-session"
        } else {
            // Pre-assigned, so resume never waits on a hook to learn the id.
            if let id = spec.agentSessionId, UUID(uuidString: id) != nil { args += " --session-id \(shellQuote(id))" }
            if let worktree = spec.worktreeName { args += " --worktree \(shellQuote(worktree))" }
        }
        return "\(enter)\(wrapper) \(args)\(options)\(extra)\(prompt)\n"
    }

    func arguments(for options: AgentOptions) -> [String] {
        var args: [String] = []
        if let model = options.model.flatMap(AgentOptions.validModel) { args += ["--model", model] }
        if let mode = options.mode {
            let value: String
            switch mode {
            case .supervised: value = "default"
            case .acceptEdits: value = "acceptEdits"
            case .plan: value = "plan"
            case .fullAccess: value = "bypassPermissions"
            }
            args += ["--permission-mode", value]
        }
        return args
    }

    let assignsSessionID = true

    func resumeCommand(_ id: String) -> String { "claude --resume \(id)" }

    // MARK: - Conversation

    let exitCommand = "/exit"
    let newConversationCommand = "/clear"

    /// Claude asks whether to keep a worktree it made (--worktree) on exit, or removes a clean
    /// one, which would leave nothing to resume in.
    func canSleep(_ spec: LaunchSpec) -> Bool { spec.worktreeName == nil }

    func transcriptFile(id: String, cwds: [String], root: URL) -> URL? {
        AgentTranscript.claudeFile(session: id, cwds: cwds, root: root)
    }

    func renderTranscript(_ text: Substring) -> [String] { AgentTranscript.renderClaude(text) }

    /// Claude's statusLine reports usage as it goes.
    func usage(id: String, root: URL) -> CodexUsage.Reading? { nil }

    let reportsStart = true
    let reportsPrompts = true

    // MARK: - Accounts

    let homeFolder = ".claude"
    let homeVariable = "CLAUDE_CONFIG_DIR"
    let historyFolder = "projects"
    let signInCommand = "claude"

    func seed(_ directory: URL, from home: URL) {
        for shared in ["settings.json", "CLAUDE.md", "agents", "commands", "skills", "plugins", "output-styles"] {
            AccountStore.link(shared, from: home, into: directory)
        }
    }

    func signedInEmail(home: URL, isDefault: Bool) -> String? {
        // The default account keeps its state in ~/.claude.json; others in <dir>/.claude.json.
        let file = isDefault
            ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
            : home.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["oauthAccount"] as? [String: Any] else { return nil }
        return oauth["emailAddress"] as? String
    }

    // MARK: - Screen and processes

    /// "Quick safety check" (new) and "Do you trust the files in this folder?" (old).
    let trustMarkers = ["yes, i trust this folder", "a project you created or one you trust", "do you trust the files in this folder"]
    /// Not checked against a signed-out Claude Code yet.
    let signInMarkers: [String] = []
    let promptMarker = "❯"
    let optionsAloneMakeDialog = false

    /// Claude's native install runs a file named for its version (…/claude/versions/2.1.289), so
    /// the kernel's name for it is "2.1.289"; its path gives it away. An npm install is node
    /// running the package's cli.js.
    func isCLIProcess(name: String, path: String?, script: String?) -> Bool {
        name == command || (path.map { $0.contains("/claude/versions/") } ?? false)
            || Self.isScript(script, package: "@anthropic-ai/claude-code", command: command)
    }
}
