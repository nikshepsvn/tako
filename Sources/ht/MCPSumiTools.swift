import Foundation

/// Sumi's board and memory tools, after the ones in `sumiToolDefinitions`.
let sumiBoardToolDefinitions: [[String: Any]] = [
    [
        "name": "standup",
        "description": "Everything about every terminal in one compact call: state and for how long, current action, todo progress, diff vs base and uncommitted files (read fresh from git), last test result, cost and context, last turn's summary, blockers (waiting on approval, failed, idle with uncommitted work), files overlapping another agent, the plan, steward warnings and account limits. Use it instead of reading terminals one by one.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "terminals": ["type": "array", "items": ["type": "string"], "description": "Only these labels (default: all)"],
            ],
        ],
    ],
    [
        "name": "plan",
        "description": """
        Your task board, kept across restarts. Tasks have an owner (an agent's label) or a folder, deps, and a brief. \
        Tako runs it: when a task's deps are done it sends the brief to its owner, or starts a new agent in its folder \
        with the brief; when the owner finishes the turn the task ran in, the task is done and the next ones start. \
        You hear each step. A task with an owner and no brief just runs (the owner was briefed when you started it). \
        Mark a task done, failed or blocked yourself with update when Tako can't tell.
        """,
        "inputSchema": [
            "type": "object",
            "properties": [
                "action": ["type": "string", "enum": ["show", "add", "update", "remove", "clear"]],
                "goal": ["type": "string", "description": "With add: what the whole plan is for"],
                "tasks": [
                    "type": "array",
                    "description": "With add: tasks to add, or replace by id",
                    "items": [
                        "type": "object",
                        "properties": [
                            "id": ["type": "string", "description": "Short id, e.g. \"api\" (default t1, t2, …)"],
                            "title": ["type": "string"],
                            "owner": ["type": "string", "description": "Agent label doing it"],
                            "deps": ["type": "array", "items": ["type": "string"], "description": "Task ids that must be done first"],
                            "brief": ["type": "string", "description": "Sent to the owner, or a new agent's task, when it becomes ready"],
                            "folder": ["type": "string", "description": "Start a new agent here when it has no live owner"],
                            "kind": ["type": "string", "enum": ["claude", "codex"]],
                        ],
                        "required": ["title"],
                    ],
                ],
                "id": ["type": "string", "description": "With update or remove: the task"],
                "status": ["type": "string", "enum": ["todo", "running", "done", "failed", "blocked"], "description": "With update"],
                "owner": ["type": "string", "description": "With update: a new owner"],
                "brief": ["type": "string", "description": "With update: a new brief"],
                "note": ["type": "string", "description": "With update: why (shown on the board)"],
            ],
            "required": ["action"],
        ],
    ],
    [
        "name": "remember",
        "description": "Keep a durable fact across conversations: a project's stack, test/build/run command or convention (section project, with its folder and a topic; a new command replaces the old one), a user preference, or a lesson learned. Each section is capped and the oldest entries drop out. forget true removes entries containing text (for project, text \"*\" forgets the user's learned approvals there). Never secrets.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "section": ["type": "string", "enum": ["project", "preference", "lesson"]],
                "text": ["type": "string", "description": "One line, e.g. \"tests: pnpm test --filter api\" or \"prefers small PRs\""],
                "project": ["type": "string", "description": "With project: its folder, absolute or ~/…"],
                "topic": ["type": "string", "enum": ["stack", "test", "build", "run", "convention", "note"], "description": "With project (default note)"],
                "forget": ["type": "boolean"],
            ],
            "required": ["section", "text"],
        ],
    ],
    [
        "name": "recall",
        "description": "What you remember: the user's preferences and lessons, and with project, that project's facts, the commands Tako detects there, and the user's past approval answers in it. Call it before starting work in a project.",
        "inputSchema": [
            "type": "object",
            "properties": ["project": ["type": "string", "description": "A project folder, absolute or ~/…"]],
        ],
    ],
]

/// The control request for one of Sumi's board tools, or nil for any other tool. The model's
/// arguments travel whole, as JSON, so the app reads them as written.
func sumiBoardRequest(_ name: String, _ arguments: [String: Any]) -> ControlRequest? {
    guard ["standup", "plan", "remember", "recall"].contains(name) else { return nil }
    var request = ControlRequest(cmd: .sumi)
    request.text = name
    let data = (try? JSONSerialization.data(withJSONObject: arguments)) ?? Data("{}".utf8)
    request.payload = String(decoding: data, as: UTF8.self)
    return request
}
