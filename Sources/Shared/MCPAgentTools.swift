import Foundation

/// Worker agents' coordination tools, appended to the MCP server's tool list: wait on another
/// terminal, read another agent's changes, share a board of notes and file claims, read a
/// server's logs precisely, and get the user's attention. Every definition is sent to every
/// agent on every turn, so descriptions stay short and related actions share one tool.
/// Shared with the app so tests cover the argument mapping.
let agentToolDefinitions: [[String: Any]] = [
    [
        "name": "wait_for",
        "description": "Wait for another terminal instead of polling read_terminal. until done (default): its turn ends (idle, failed, exited) or it waits on the user; returns at once if already at rest. pattern: instead wait for a new output line matching this regex (e.g. \"ready|error\"). Returns its state and summary, or the line. terminals: wait on several, until all (default) or any is done; returns each one's outcome.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "terminal": ["type": "string", "description": "Label, e.g. \"@api\""],
                "terminals": ["type": "array", "items": ["type": "string"]],
                "mode": ["type": "string", "enum": ["all", "any"]],
                "until": ["type": "string", "enum": ["done", "needs-input", "exited"]],
                "pattern": ["type": "string"],
                "timeout": ["type": "integer", "description": "Seconds (default 600, max 1500)"],
            ],
        ],
    ],
    [
        "name": "agent_changes",
        "description": "An agent's work as Git sees it, to review or build on: workspace, branch, commits since its base, changed files with +/− counts. scope uncommitted: only uncommitted work. patch adds the diff; paths limits it. Omit terminal for your own.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "terminal": ["type": "string", "description": "Label, e.g. \"@api\""],
                "scope": ["type": "string", "enum": ["branch", "uncommitted"]],
                "patch": ["type": "boolean"],
                "paths": ["type": "array", "items": ["type": "string"]],
            ],
        ],
    ],
    [
        "name": "team_board",
        "description": "Board shared by the agents in this repo, across worktrees. read: notes and file claims (since n skips n notes). note: post a decision or API contract (text). claim: reserve paths (files, folders, globs; repo-relative) before editing; ones someone else holds are refused and the holder asked to release. release: drop claims (paths, or all). Claims end when you exit or after minutes (default 120).",
        "inputSchema": [
            "type": "object",
            "properties": [
                "action": ["type": "string", "enum": ["read", "note", "claim", "release"]],
                "text": ["type": "string"],
                "paths": ["type": "array", "items": ["type": "string"]],
                "minutes": ["type": "integer"],
                "since": ["type": "integer"],
            ],
            "required": ["action"],
        ],
    ],
    [
        "name": "server_logs",
        "description": "A server's (or agent's) recent output, filtered: grep (regex), errors (error lines with stack traces), since (cursor from a previous call: newer lines only), lines (default 100, max 500). Cheaper than read_terminal for logs.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "terminal": ["type": "string", "description": "Label, e.g. \"@web\""],
                "grep": ["type": "string"],
                "errors": ["type": "boolean"],
                "since": ["type": "string"],
                "lines": ["type": "integer"],
            ],
            "required": ["terminal"],
        ],
    ],
    [
        "name": "notify_user",
        "description": "Notify the user now (macOS notification, mark on your card) without ending your turn: a result to check, a decision you're blocked on. Not for routine progress.",
        "inputSchema": [
            "type": "object",
            "properties": ["text": ["type": "string"]],
            "required": ["text"],
        ],
    ],
]

/// wait_for's timeout, in seconds. The cap stays under Claude Code's 30-minute idle limit for
/// a stdio tool call.
let agentWaitDefault = 600
let agentWaitMax = 1500

/// wait_for holds its call open for minutes, so the MCP server answers it off its read loop.
func agentToolBlocks(_ name: String) -> Bool { name == "wait_for" }

/// The control request behind one of these tools, or nil when `name` isn't one of them.
func agentToolRequest(_ name: String, _ arguments: [String: Any]) -> ControlRequest? {
    var req: ControlRequest
    switch name {
    case "wait_for":
        req = ControlRequest(cmd: .wait)
        req.target = arguments["terminal"] as? String
        req.targets = (arguments["terminals"] as? [String])
            ?? (arguments["terminals"] as? String).map { $0.split(separator: ",").map(String.init) }
        req.mode = arguments["mode"] as? String
        req.text = arguments["until"] as? String
        req.pattern = arguments["pattern"] as? String
        req.timeout = arguments["timeout"] as? Int
    case "agent_changes":
        req = ControlRequest(cmd: .changes)
        req.target = arguments["terminal"] as? String
        req.text = arguments["scope"] as? String
        req.flag = arguments["patch"] as? Bool
        req.paths = arguments["paths"] as? [String]
    case "team_board":
        req = ControlRequest(cmd: .board)
        req.text = arguments["action"] as? String
        req.label = arguments["text"] as? String
        req.paths = (arguments["paths"] as? [String]) ?? (arguments["paths"] as? String).map { [$0] }
        req.timeout = arguments["minutes"] as? Int
        req.since = (arguments["since"] as? Int).map(String.init)
    case "server_logs":
        req = ControlRequest(cmd: .logs)
        req.target = arguments["terminal"] as? String
        req.pattern = arguments["grep"] as? String
        req.flag = arguments["errors"] as? Bool
        req.since = arguments["since"] as? String
        req.lines = arguments["lines"] as? Int
    case "notify_user":
        req = ControlRequest(cmd: .notify)
        req.text = arguments["text"] as? String
    default:
        return nil
    }
    return req
}

/// How long the MCP server waits on Tako's reply: past a wait's own timeout, and long enough
/// for Git on a big repository. Nil waits as long as the reply takes.
func agentToolSocketTimeout(_ request: ControlRequest) -> Int? {
    switch request.cmd {
    case .wait: return min(max(request.timeout ?? agentWaitDefault, 1), agentWaitMax) + 15
    case .changes: return 120
    default: return nil
    }
}
