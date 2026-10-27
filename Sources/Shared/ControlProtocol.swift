import Foundation

/// Wire protocol between the Tako app and the `ht` CLI / hooks / MCP bridge.
/// One JSON object per line over a Unix domain socket, one request per connection.
enum ControlCommand: String, Codable {
    case list          // list sessions
    case new           // create a session
    case send          // deliver a message into a session (typed into its terminal)
    case read          // read a session's screen text
    case focus         // focus a session in the UI
    case close         // close a session
    case restart       // restart a session with the same launch spec
    case rename        // change a session label
    case hook          // lifecycle event from an agent hook (Claude / Codex)
    case notify        // explicit attention notification
    case key           // press named keys in a terminal (user only)
    case layout        // switch layout: focus | split | grid (text)
    case status        // an agent posts a one-line status for its card (text)
    case approve       // answer a pending prompt: text = approve | always | deny (user only)
    case permission    // PermissionRequest hook, held open until the user decides
    case statusline    // Claude statusLine JSON (cost, context, rate limits)
    case subscribe     // channel long-poll from an agent's MCP server: returns queued messages
    case browser       // start the embedded browser if needed; text = its DevTools endpoint
    case arrange       // Sumi arranges the view: text = layout, target = focus, tiles
    case layouts       // Sumi's named layouts: text = save | restore | list, label = name
    case watch         // Sumi hears when target finishes; text = its note for then
    case history       // Sumi's closed sessions: text = list | reopen, targets for reopen
    case heavy         // heavy-job slot: text = acquire (replies when granted) | release, pid = holder
    case detach        // Sumi pops tiles into their own windows: text = out | back, targets
    case machine       // Sumi and the steward: text = status | policy (count = agent cap, targets = pinned)
    case delegate      // Sumi handles target's waits: text = handle | stop | list (label = scope, count, note)
    case phoneMode     // Phone Mode, from the user or Sumi: text = on | off | status
    case act           // Sumi acts on an agent: text = choose (options) | trust | signin | interrupt (hard)
                       // | keys (keys) | type (text in label, submit) | restart | mode (mode)
    case sumi          // Sumi's board and memory: text = standup | plan | remember | recall, payload = arguments JSON
    // Worker coordination tools (MCPAgentTools):
    case wait          // block until target reaches text = done | needs-input | exited, or prints `pattern`
    case changes       // target's diff: text = branch | uncommitted, patch, paths
    case board         // the project's team board: text = read | note | claim | release
    case logs          // target's output filtered: pattern (grep), errors in submit, since, lines
    // Sumi's on-demand cleanup:
    case orphans       // processes Tako started whose terminal is gone: text = list | kill, targets = pids
    case doctor        // Tako's health summary, for the user (`ht doctor`) or Sumi
}

struct ControlRequest: Codable {
    var cmd: ControlCommand
    /// Target session: label (with or without leading @) or session id.
    var target: String?
    /// Session id of the caller, taken from $HT_SESSION_ID. Used as the sender of messages.
    var from: String?
    var label: String?
    var kind: String?
    var cwd: String?
    var command: String?
    var text: String?
    var lines: Int?
    /// Hook source, e.g. "claude" or "codex-notify".
    var source: String?
    /// Raw hook payload (JSON string as received on stdin/argv).
    var payload: String?
    /// For `send`: type the text and press Enter (default true). False pastes without submitting.
    var submit: Bool?
    /// For `key`: names like "enter", "down", "esc", "tab", "y", "ctrl-c".
    var keys: [String]?
    /// For `new`: give an agent its own git worktree and branch.
    var worktree: Bool?
    /// For `new`: the Claude/Codex account an agent runs on.
    var account: String?
    /// For `hook`: when the hook process started (continuous clock, ns), to order events.
    var sentAt: UInt64?
    /// For `arrange`: the grid's tiles, as a tree of splits whose leaves are labels.
    var tiles: TileSpec?
    /// For `new` from Sumi: how many agents take the same task.
    var count: Int?
    /// For `history` reopen: labels or ids of closed sessions.
    var targets: [String]?
    /// For `heavy`: the process holding the slot; it is released when that process exits.
    var pid: Int32?
    /// For `delegate` handle: the user's instructions for Sumi.
    var note: String?
    /// For `approve` from Sumi in Phone Mode: the user said yes to this request on their phone.
    var userApproved: Bool?
    /// For Sumi's `act` and `close`: the user asked for this directly, in their own words, in the
    /// turn Sumi is acting in. Tako checks that the turn was the user's (`turnFromUser`).
    var userRequested: Bool?
    /// For Sumi's `close` with `userRequested`: close even with work at risk; the user said so.
    var force: Bool?
    /// For Sumi's `new`: seconds to wait for each agent to reach its prompt (0: don't wait).
    var wait: Int?
    /// For `browser`: a page to open in the caller's browser (a URL, an address, or a file URL).
    var url: String?
    /// For `act` choose: option numbers, one per question of a form (the first alone for a menu).
    var options: [Int]?
    /// For `act` mode: a PermissionMode raw value.
    var mode: String?
    /// For `act` interrupt: Ctrl-C instead of Esc.
    var hard: Bool?
    /// For `wait` and `logs`: a regular expression output lines are matched against.
    var pattern: String?
    /// For `wait`: seconds before giving up. For `board` claim: minutes the claim lasts.
    var timeout: Int?
    /// For `logs`: the cursor a previous read returned; only lines after it come back.
    var since: String?
    /// For `changes`: include the patch. For `logs`: only error lines.
    var flag: Bool?
    /// For `changes` and `board`: files or globs, relative to the workspace root.
    var paths: [String]?
    /// For `subscribe`: ids of the channel messages this poller has written to Claude since its
    /// last poll. Sent, even empty, only by pollers that confirm; an older `ht` leaves it out
    /// and its hand-off counts as delivery, as before.
    var acks: [String]?
}

/// The most agents one start_agent call may start on the same task.
let sumiStartCap = 5

/// A tile arrangement as an agent describes it: a leaf names a terminal, a split lays its
/// children side by side (`row`) or stacked (`column`), sized by `sizes` (even when omitted).
struct TileSpec: Codable, Equatable {
    var terminal: String?
    var split: String?
    var sizes: [Double]?
    var children: [TileSpec]?
}

struct SessionInfo: Codable, Equatable {
    var id: String
    var label: String
    var kind: String
    var state: String
    var stateDetail: String?
    var summary: String?
    var title: String?
    var cwd: String
    var command: String?
    var ports: [Int]
    var unread: Bool
    var agentSessionId: String?
    /// "user", "auto", or "agent".
    var labelSource: String?
    var activity: String?
    var project: String?
    var branch: String?
    /// The agent behind the sidebar's box, which runs the user's other sessions.
    var sumi: Bool?
    /// Agents whose workspaces would conflict with this one's if merged, by label, with the files.
    var conflicts: [String: [String]]?
    /// The agent CLI quit to free memory; a message or keystroke resumes its conversation.
    var asleep: Bool?
    /// Sumi handles its waits: "turn", "2 left", "until 14:05".
    var delegation: String? = nil
    /// Shown in its own window instead of the canvas.
    var detached: Bool? = nil
    /// Claude subagents still running, which may outlast the session's own turn.
    var subagents: Int? = nil
    /// Files and globs this agent claimed on its project's team board.
    var claims: [String]? = nil

    /// `sumi` keeps its old wire name, so an `ht` from before the rename still reads it.
    enum CodingKeys: String, CodingKey {
        case id, label, kind, state, stateDetail, summary, title, cwd, command, ports, unread, agentSessionId
        case labelSource, activity, project, branch, conflicts, asleep, delegation, detached, subagents, claims
        case sumi = "organizer"
    }
}

struct ControlResponse: Codable {
    var ok: Bool
    /// For `subscribe`: messages to push into the session as channel events.
    var messages: [String]?
    /// For `subscribe`: each message's id, in order, for the poller to acknowledge.
    var messageIDs: [String]?
    var error: String?
    var sessions: [SessionInfo]?
    var session: SessionInfo?
    var text: String?
    /// For `browser`: the DevTools endpoint the browser is actually listening on.
    var endpoint: String?

    static func success(text: String? = nil) -> ControlResponse {
        ControlResponse(ok: true, text: text)
    }

    static func failure(_ message: String) -> ControlResponse {
        ControlResponse(ok: false, error: message)
    }
}

enum ControlPaths {
    static let directoryName = ".tako"
    /// The folder's name before the rename to Tako. The app moves it to ~/.tako at launch and
    /// leaves a symlink here for good: PATH lines, git worktree metadata, saved sessions and
    /// agent configs all hold absolute ~/.hyperterm paths.
    static let legacyDirectoryName = ".hyperterm"

    /// ~/.tako: short and space-free because these paths are typed into shells and embedded in
    /// agent configs. $HT_HOME moves it, so a dev build (scripts/run.sh) keeps its sessions,
    /// socket and browser profile apart from the installed app's.
    static var supportDirectory: URL {
        resolveSupportDirectory(home: FileManager.default.homeDirectoryForCurrentUser,
                                environment: ProcessInfo.processInfo.environment)
    }

    /// The pre-rename folder in the user's home, whether it is still a folder or now a symlink.
    static var legacySupportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(legacyDirectoryName, isDirectory: true)
    }

    /// Shared by the app and `ht`, so both find the same folder before and after the app's move:
    /// a real ~/.hyperterm with no ~/.tako is an install the new app hasn't launched on yet.
    static func resolveSupportDirectory(home: URL, environment: [String: String]) -> URL {
        if let env = environment["HT_HOME"], !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        let current = home.appendingPathComponent(directoryName, isDirectory: true)
        let legacy = home.appendingPathComponent(legacyDirectoryName, isDirectory: true)
        let fm = FileManager.default
        if fm.fileExists(atPath: current.path) { return current }
        let isSymlink = (try? fm.attributesOfItem(atPath: legacy.path)[.type] as? FileAttributeType) == .typeSymbolicLink
        if !isSymlink, fm.fileExists(atPath: legacy.path) { return legacy }
        return current
    }

    /// $HT_SOCKET wins so sessions always talk to the app instance that spawned them.
    static var socketPath: String {
        if let env = ProcessInfo.processInfo.environment["HT_SOCKET"], !env.isEmpty { return env }
        return supportDirectory.appendingPathComponent("control.sock").path
    }

    /// Sumi's own notes: the user's preferences, project folders and open threads.
    static var sumiNotes: String {
        supportDirectory.appendingPathComponent("organizer-notes.md").path
    }
}

/// Default names for new agents and shells, used in order: short to say, and each one's first
/// letter also finds it ("b" is @bravo).
let phoneticLabels = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel", "india",
                      "juliet", "kilo", "lima", "mike", "november", "oscar", "papa", "quebec", "romeo",
                      "sierra", "tango", "uniform", "victor", "whiskey", "xray", "yankee", "zulu"]

/// Normalizes "@api", "api", " API " to "api".
func normalizeLabel(_ raw: String) -> String {
    var label = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if label.hasPrefix("@") { label.removeFirst() }
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
    label = String(label.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
    return label
}

/// Key for a JSON-RPC request id that keeps the id's type: integer 1 and string "1" are different ids.
func mcpRequestKey(_ id: Any) -> String {
    id is String ? "s:\(id)" : "n:\(id)"
}
