import Foundation

// ht: command-line control for Tako. Also the hook entry point for agents and the
// stdio MCP server that lets agents talk to each other by @label.

let usage = """
usage: ht <command>

  ls [--json]                      list terminals with status, summary, ports
  send @label <text> [--no-enter]  type a message into a terminal and submit it
  read @label [-n lines]           print a terminal's recent output (default 60 lines)
  new <claude|codex|shell|server|browser> [@label] [--cwd dir] [--worktree] [--account name] [--task "…"] [-- command…]
  approve|always|deny @label        answer the prompt an agent is waiting on
  status <text>                    set this agent's card status (inside an agent terminal)
  key @label <key>…                press keys, e.g. `ht key @api down enter` (enter, esc, tab,
                                   up/down/left/right, space, backspace, a-z, 0-9, ctrl-c)
  focus @label                     bring a terminal to the front
  layout <focus|split|grid>        switch how many terminals are on screen
  restart @label                   restart a terminal's process
  rename @label <new-label>
  close @label
  whoami                           this terminal's label (inside Tako)
  mcp                              run the MCP server (used by agents)
  browser [url|file]               open the embedded browser, on a URL or local .html file; prints its DevTools endpoint
  browser-mcp [port]               run the browser MCP server (used by agents)
  mcp-lazy --name n -- <command…>  run a stdio MCP server, started on first use (used by agents)
  hook <source> [payload]          forward an agent hook event (used by agents)
  heavy -- <command…>              wait for a heavy-job slot (builds, tests), then run the command
"""

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let env = ProcessInfo.processInfo.environment
let callerSession = env["HT_SESSION_ID"]

func request(_ cmd: ControlCommand, configure: (inout ControlRequest) -> Void = { _ in }) -> ControlResponse {
    var req = ControlRequest(cmd: cmd)
    configure(&req)
    do {
        return try sendControlRequest(req)
    } catch {
        fail("ht: \(error)")
    }
}

func requireOK(_ response: ControlResponse) -> ControlResponse {
    if !response.ok { fail("ht: \(response.error ?? "failed")") }
    return response
}

func formatTable(_ sessions: [SessionInfo]) -> String {
    guard !sessions.isEmpty else { return "no terminals" }
    let rows = sessions.map { info -> [String] in
        let state = info.stateDetail.map { "\(info.state): \($0)" } ?? info.state
        let ports = info.ports.map { ":\($0)" }.joined(separator: " ")
        return ["@" + info.label, info.kind, state, ports, info.summary ?? info.cwd]
    }
    let widths = (0..<4).map { col in rows.map { $0[col].count }.max() ?? 0 }
    return rows.map { row in
        (0..<4).map { row[$0].padding(toLength: min(widths[$0], 40), withPad: " ", startingAt: 0) }.joined(separator: "  ")
            + "  " + String(row[4].prefix(80))
    }.joined(separator: "\n")
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { print(usage); exit(0) }
args.removeFirst()

switch command {
case "ls", "list":
    let response = requireOK(request(.list))
    if args.contains("--json") {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: (try? encoder.encode(response.sessions ?? [])) ?? Data(), as: UTF8.self))
    } else {
        print(formatTable(response.sessions ?? []))
    }

case "send":
    guard args.count >= 2 else { fail("usage: ht send @label <text> [--no-enter]") }
    let submit = !args.contains("--no-enter")
    let target = args[0]
    let text = args.dropFirst().filter { $0 != "--no-enter" }.joined(separator: " ")
    let response = requireOK(request(.send) {
        $0.target = target
        $0.text = text
        $0.from = callerSession
        $0.submit = submit
    })
    print(response.text ?? "sent")

case "read":
    guard let target = args.first else { fail("usage: ht read @label [-n lines]") }
    var lines = 60
    if let index = args.firstIndex(of: "-n"), index + 1 < args.count, let n = Int(args[index + 1]) { lines = n }
    print(requireOK(request(.read) { $0.target = target; $0.lines = lines }).text ?? "")

case "new":
    guard let kind = args.first else { fail("usage: ht new <claude|codex|shell|server|browser> [@label] [--cwd dir] [--account name] [-- command…]") }
    var rest = Array(args.dropFirst())
    var commandParts: [String] = []
    if let dash = rest.firstIndex(of: "--") {
        commandParts = Array(rest[(dash + 1)...])
        rest = Array(rest[..<dash])
    }
    var cwd = FileManager.default.currentDirectoryPath
    let worktree = rest.contains("--worktree")
    rest.removeAll { $0 == "--worktree" }
    if let index = rest.firstIndex(of: "--cwd"), index + 1 < rest.count {
        cwd = (rest[index + 1] as NSString).expandingTildeInPath
        rest.removeSubrange(index...(index + 1))
    }
    var account: String?
    if let index = rest.firstIndex(of: "--account"), index + 1 < rest.count {
        account = rest[index + 1]
        rest.removeSubrange(index...(index + 1))
    }
    let task = rest.firstIndex(of: "--task").flatMap { $0 + 1 < rest.count ? rest[$0 + 1] : nil }
    if let index = rest.firstIndex(of: "--task") { rest.removeSubrange(index...min(index + 1, rest.count - 1)) }
    let response = requireOK(request(.new) {
        $0.text = task
        $0.kind = kind
        $0.label = rest.first
        $0.cwd = cwd
        $0.command = commandParts.isEmpty ? nil : commandParts.joined(separator: " ")
        $0.from = callerSession
        $0.worktree = worktree
        $0.account = account
    })
    print(response.text ?? "created")

case "key", "keys":
    guard args.count >= 2 else { fail("usage: ht key @label <key>…") }
    _ = requireOK(request(.key) { $0.target = args[0]; $0.keys = Array(args.dropFirst()) })

case "approve", "always", "deny":
    guard let target = args.first else { fail("usage: ht \(command) @label [reason]") }
    let reason = args.count > 1 ? args.dropFirst().joined(separator: " ") : nil
    print(requireOK(request(.approve) { $0.target = target; $0.text = command; $0.label = reason }).text ?? command)

case "status":
    let target = args.first?.hasPrefix("@") == true ? args.first : nil
    let text = args.dropFirst(target == nil ? 0 : 1).joined(separator: " ")
    print(requireOK(request(.status) { $0.text = text; $0.target = target }).text ?? "ok")

case "layout":
    guard let mode = args.first else { fail("usage: ht layout <focus|split|grid>") }
    _ = requireOK(request(.layout) { $0.text = mode })

case "focus", "close", "restart":
    guard let target = args.first else { fail("usage: ht \(command) @label") }
    let cmd: ControlCommand = command == "focus" ? .focus : command == "close" ? .close : .restart
    let response = requireOK(request(cmd) { $0.target = target; $0.from = callerSession })
    if let text = response.text { print(text) }

case "rename":
    guard args.count == 2 else { fail("usage: ht rename @label <new-label>") }
    print(requireOK(request(.rename) { $0.target = args[0]; $0.label = args[1] }).text ?? "renamed")

case "whoami":
    guard let label = env["HT_LABEL"] else { fail("not running inside Tako") }
    print("@" + label)

case "hook":
    // Hooks must never block or fail the agent: swallow every error and exit 0.
    let source = args.first ?? "unknown"
    let payload: String
    if args.count > 1 {
        payload = args[1]
    } else {
        payload = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    }
    if callerSession != nil {
        var req = ControlRequest(cmd: .hook)
        req.source = source
        req.payload = payload
        // Stamped at start so the app can drop events that lose the race to the socket.
        req.sentAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        _ = try? sendControlRequest(req, timeout: 5)
    }
    exit(0)

case "permission":
    // PermissionRequest hook: wait for the user's decision in Tako and print it. Printing
    // nothing leaves the CLI's own prompt in charge. Never fail the agent.
    let source = args.first ?? "claude"
    let payload = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    var req = ControlRequest(cmd: .permission)
    req.source = source
    req.payload = payload
    if callerSession != nil, let response = try? sendControlRequest(req, timeout: 590), let decision = response.text, !decision.isEmpty {
        print(decision)
    }
    exit(0)

case "statusline":
    // Claude statusLine: report telemetry to Tako when it changed, then print the user's own
    // statusline (cached briefly; see StatusLineRunner for why every step is trimmed).
    let input = FileHandle.standardInput.readDataToEndOfFile()
    if let callerSession, StatusLineRunner.reportDue(session: callerSession, input: input) {
        var req = ControlRequest(cmd: .statusline)
        req.payload = String(decoding: input, as: UTF8.self)
        _ = try? sendControlRequest(req, timeout: 1)
    }
    FileHandle.standardOutput.write(StatusLineRunner.render(input: input, environment: env))
    exit(0)

case "mcp":
    runMCPServer()

case "browser-mcp":
    let port = args.first.flatMap(Int.init) ?? 9339
    runBrowserMCP(port: port)

case "mcp-lazy":
    runLazyMCP(args)

case "mcp-lazy-config":
    runLazyMCPConfig(args)

case "heavy":
    runHeavy(args)

case "browser":
    let target = args.first.map { BrowserTarget.address($0, cwd: FileManager.default.currentDirectoryPath) }
    print(requireOK(request(.browser) { $0.from = callerSession; $0.url = target }).text ?? "")

case "-h", "--help", "help":
    print(usage)

default:
    fail("ht: unknown command '\(command)'\n\n\(usage)")
}
