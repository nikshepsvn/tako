import Foundation

/// `ht mcp-lazy --name <name> [--env-keys A,B] -- <command> <args…>`: one of the user's own stdio
/// MCP servers, started when the agent first uses it rather than when the agent starts. Each
/// agent still gets its own copy.
///
/// - With a cache (LazyMCP.cacheDirectory, keyed by command, args and the values of `--env-keys`),
///   the handshake, ping and tools/prompts/resources lists are answered from it; the server starts
///   on the first other request, gets the agent's handshake replayed, and from then on everything
///   is forwarded both ways.
/// - Without one, the server starts at once and is forwarded transparently.
/// - After each start the cache is refreshed from the real server; lists the agent was given from
///   a stale cache are announced as changed. If the server exits, the next request starts it again.
func runLazyMCP(_ args: [String]) -> Never {
    let usage = "usage: ht mcp-lazy --name <name> [--env-keys A,B] -- <command> <args…>"
    guard let dash = args.firstIndex(of: "--"), dash + 1 < args.count else { fail(usage) }
    var name = "server", envKeys: [String] = []
    var options = args[..<dash].makeIterator()
    while let option = options.next() {
        switch option {
        case "--name": name = options.next() ?? name
        case "--env-keys": envKeys = (options.next() ?? "").split(separator: ",").map(String.init)
        default: fail(usage)
        }
    }
    let command = Array(args[(dash + 1)...])
    let configured = Dictionary(uniqueKeysWithValues: envKeys.compactMap { key in env[key].map { (key, $0) } })
    let key = LazyMCP.cacheKey(command: command[0], arguments: Array(command.dropFirst()), environment: configured)
    LazyProxy(name: name, command: command, cacheURL: LazyMCP.cacheDirectory.appendingPathComponent(key + ".json")).run()
}

/// `ht mcp-lazy-config claude|codex`, run by the agent wrappers in the launch directory. Claude:
/// prints the path of an --mcp-config file that replaces the user's stdio servers with
/// `ht mcp-lazy`; Codex: prints shell-quoted `-c` overrides. Prints nothing when there is nothing
/// to wrap. Servers named in HT_MCP_EAGER are left as they are.
func runLazyMCPConfig(_ args: [String]) -> Never {
    let eager = Set((env["HT_MCP_EAGER"] ?? "").split(separator: ",").map(String.init))
    let home = FileManager.default.homeDirectoryForCurrentUser
    let ht = selfPath()
    switch args.first {
    case "claude":
        let configURL = env["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0).appendingPathComponent(".claude.json") }
            ?? home.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: configURL),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { exit(0) }
        let cwd = FileManager.default.currentDirectoryPath
        // Claude keeps local-scope servers under the repository's main checkout.
        let projects = config["projects"] as? [String: Any] ?? [:]
        let project = [gitRoot(cwd), cwd].compactMap { $0 }.first { projects[$0] != nil } ?? cwd
        let servers = LazyMCP.claudeServers(config: config, projectPath: project, ht: ht, eager: eager)
        guard !servers.isEmpty,
              let out = try? JSONSerialization.data(withJSONObject: ["mcpServers": servers], options: [.sortedKeys, .withoutEscapingSlashes])
        else { exit(0) }
        // The servers' env may hold secrets: a private file, not an argument anyone can see in ps.
        let dir = ControlPaths.supportDirectory.appendingPathComponent("mcp-lazy", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = dir.appendingPathComponent("claude-\(LazyMCP.cacheKey(command: String(decoding: out, as: UTF8.self), arguments: [], environment: [:]).prefix(16)).json")
        guard FileManager.default.createFile(atPath: file.path, contents: out, attributes: [.posixPermissions: 0o600]) else { exit(0) }
        print(file.path)
    case "codex":
        let configURL = env["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".codex")
        guard let toml = try? String(contentsOf: configURL.appendingPathComponent("config.toml"), encoding: .utf8) else { exit(0) }
        let overrides = LazyMCP.codexOverrides(configTOML: toml, ht: ht, eager: eager)
        print(overrides.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " "))
    default:
        fail("usage: ht mcp-lazy-config <claude|codex>")
    }
    exit(0)
}

/// The path this ht was started by (the wrappers use ~/.hyperterm/bin/ht, which survives the app moving).
private func selfPath() -> String {
    let invoked = CommandLine.arguments[0]
    if invoked.contains("/") {
        return URL(fileURLWithPath: invoked, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL.path
    }
    return Bundle.main.executablePath ?? invoked
}

/// The main checkout's root for a repository or any of its worktrees.
private func gitRoot(_ directory: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git", "-C", directory, "rev-parse", "--path-format=absolute", "--git-common-dir"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard process.terminationStatus == 0, path.hasSuffix("/.git") else { return nil }
    return String(path.dropLast(5))
}

/// Lists answered from the cache, and the notification that tells the agent one changed.
private let cachedLists: [(method: String, capability: String, changed: String)] = [
    ("tools/list", "tools", "notifications/tools/list_changed"),
    ("prompts/list", "prompts", "notifications/prompts/list_changed"),
    ("resources/list", "resources", "notifications/resources/list_changed"),
    ("resources/templates/list", "resources", "notifications/resources/list_changed"),
]

private final class LazyProxy: @unchecked Sendable {
    private let name: String
    private let command: [String]
    private let cacheURL: URL
    /// The agent's initialize, initialized and logging/setLevel, replayed to each server started.
    private var handshake: [String] = []
    private let outputLock = NSLock()
    private let stateLock = NSLock()
    /// Held while the server starts, so it starts once.
    private let startLock = NSLock()

    // Guarded by stateLock.
    /// { "protocolVersion": the agent's request, "initialize": result, "<list method>": result }.
    private var cache: [String: Any]?
    /// List methods the agent was answered from the cache since the server last started.
    private var answeredFromCache: Set<String> = []
    private var child: Process?
    private var toChild: FileHandle?
    /// The running server's initialize result.
    private var serverInitialize: [String: Any]?
    /// The agent's own initialize, sent straight to a server when there was no cache.
    private var directInitializeID: String?
    /// The agent's server/discover probe sent to a server, and the version it asked about.
    private var directDiscover: (key: String, version: String?)?
    /// A server that refused server/discover: { "protocolVersion", "error" }, answered from the
    /// cache like the handshake. One that accepts it is never answered from the cache.
    private var discoverRefusal: [String: Any]?
    /// Agent requests the running server hasn't answered, by id key; failed if it exits.
    private var pending: [String: Any] = [:]
    private var hiddenReplies: [String: [String: Any]] = [:]
    private var hiddenWaiters: [String: DispatchSemaphore] = [:]
    private var hiddenCounter = 0
    /// Last request to or reply from the server: one idle past `idleLimit` is stopped and starts
    /// again on the next request, so a tool used once doesn't hold its memory (a whole Chrome,
    /// for some) until the agent exits.
    private var lastActivity = Date()
    private static let idleLimit: TimeInterval = 600

    init(name: String, command: [String], cacheURL: URL) {
        self.name = name
        self.command = command
        self.cacheURL = cacheURL
        cache = (try? Data(contentsOf: cacheURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    func run() -> Never {
        signal(SIGPIPE, SIG_IGN)
        // The server goes when the agent does.
        var sources: [DispatchSourceSignal] = []
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler { [self] in
                withState { self.child }?.terminate()
                exit(0)
            }
            source.resume()
            sources.append(source)
        }
        let idle = DispatchSource.makeTimerSource(queue: .global())
        idle.schedule(deadline: .now() + 60, repeating: 60)
        idle.setEventHandler { [self] in stopIfIdle() }
        idle.resume()
        while let line = readLine(strippingNewline: false) {
            handleAgentLine(line)
        }
        idle.cancel()
        let (process, input) = withState { (self.child, self.toChild) }
        try? input?.close()
        if let process {
            let deadline = Date().addingTimeInterval(3)
            while process.isRunning && Date() < deadline { usleep(50_000) }
            if process.isRunning { process.terminate() }
        }
        exit(0)
    }

    // MARK: - Agent → server

    private var serverRunning: Bool { withState { self.child != nil } }

    private func handleAgentLine(_ line: String) {
        guard let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let method = message["method"] as? String else {
            // Replies to the server's own requests, or nothing we understand.
            sendToChild(line)
            return
        }
        let id = message["id"]
        if method == "initialize" {
            handleInitialize(message, line: line, id: id)
            return
        }
        if method == "notifications/initialized" || method == "logging/setLevel" { handshake.append(line) }
        if method == "server/discover", let id {
            let version = ((message["params"] as? [String: Any])?["_meta"] as? [String: Any])?["io.modelcontextprotocol/protocolVersion"] as? String
            let refusal = withState { self.cache?[method] as? [String: Any] }
            if !serverRunning, let refusal, refusal["protocolVersion"] as? String == version, let error = refusal["error"] {
                writeToAgent(["jsonrpc": "2.0", "id": id, "error": error])
                return
            }
            withState { self.directDiscover = (mcpRequestKey(id), version) }
        }
        if serverRunning {
            if let id { forward(line, id: id) } else { sendToChild(line) }
            if method == "notifications/initialized", withState({ self.serverInitialize != nil }) {
                DispatchQueue.global().async { self.refreshCache() }
            }
            return
        }
        // Notifications wait for the server; the handshake ones are replayed to it.
        guard let id else { return }
        if method == "ping" || method == "logging/setLevel" {
            writeToAgent(["jsonrpc": "2.0", "id": id, "result": [String: Any]()])
            return
        }
        let paged = (message["params"] as? [String: Any])?["cursor"] != nil
        if let list = cachedLists.first(where: { $0.method == method }), !paged {
            let (cached, capabilities) = withState { () -> (Any?, [String: Any]?) in
                (self.cache?[method], (self.cache?["initialize"] as? [String: Any])?["capabilities"] as? [String: Any])
            }
            if let cached {
                withState { _ = self.answeredFromCache.insert(method) }
                writeToAgent(["jsonrpc": "2.0", "id": id, "result": cached])
                return
            }
            if let capabilities, capabilities[list.capability] == nil {
                replyRPCError(id: id, code: -32601, "Method not found: \(method)")
                return
            }
        }
        startLock.lock()
        let started = serverRunning || startServer(replay: true)
        startLock.unlock()
        guard started else {
            replyRPCError(id: id, "Couldn't start the \(name) MCP server (\(command.joined(separator: " "))).")
            return
        }
        forward(line, id: id)
    }

    private func handleInitialize(_ message: [String: Any], line: String, id: Any?) {
        handshake = [line]
        guard let id else { return }
        let requested = (message["params"] as? [String: Any])?["protocolVersion"] as? String
        if !serverRunning, let cached = withState({ self.cache }), cached["protocolVersion"] as? String == requested,
           let result = cached["initialize"] {
            writeToAgent(["jsonrpc": "2.0", "id": id, "result": result])
            return
        }
        // No cache for this server and protocol yet: start it now and let it answer.
        startLock.lock()
        let started = serverRunning || startServer(replay: false)
        startLock.unlock()
        guard started else {
            replyRPCError(id: id, "Couldn't start the \(name) MCP server (\(command.joined(separator: " "))).")
            return
        }
        withState { self.directInitializeID = mcpRequestKey(id) }
        forward(line, id: id)
    }

    /// Sends an agent request to the server, failing it if there is no server to answer.
    private func forward(_ line: String, id: Any) {
        let key = mcpRequestKey(id)
        let registered = withState { () -> Bool in
            guard self.child != nil else { return false }
            self.lastActivity = Date()
            self.pending[key] = id
            return true
        }
        guard registered, sendToChild(line) else {
            let orphaned = withState { self.pending.removeValue(forKey: key) != nil || !registered }
            if orphaned { replyRPCError(id: id, "The \(name) MCP server isn't running. Try again to restart it.") }
            return
        }
    }

    // MARK: - Server process

    private func stopIfIdle() {
        let process = withState { () -> Process? in
            guard let child = self.child, self.pending.isEmpty, self.hiddenWaiters.isEmpty,
                  Date().timeIntervalSince(self.lastActivity) > Self.idleLimit else { return nil }
            return child
        }
        if let process { stopServer(process) }
    }

    /// Starts the server; with `replay`, gives it the agent's handshake first.
    private func startServer(replay: Bool) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        do { try process.run() } catch {
            FileHandle.standardError.write(Data("ht: couldn't start \(name): \(error)\n".utf8))
            return false
        }
        withState {
            self.child = process
            self.toChild = input.fileHandleForWriting
            self.serverInitialize = nil
        }
        Thread.detachNewThread { [self] in relayServerOutput(from: output, of: process) }
        guard replay else { return true }
        for line in handshake {
            guard let message = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            guard message["id"] != nil else {
                sendToChild(line)
                continue
            }
            // The first start may include npx or uvx downloading the package.
            let reply = hiddenRequest(message, timeout: message["method"] as? String == "initialize" ? 120 : 15)
            guard message["method"] as? String == "initialize" else { continue }
            guard let result = reply?["result"] as? [String: Any] else {
                stopServer(process)
                return false
            }
            withState { self.serverInitialize = result }
        }
        guard withState({ self.child === process }) else { return false }
        DispatchQueue.global().async { self.refreshCache() }
        return true
    }

    private func stopServer(_ process: Process) {
        let input = withState { () -> FileHandle? in
            guard self.child === process else { return nil }
            self.child = nil
            defer { self.toChild = nil }
            return self.toChild
        }
        try? input?.close()
        process.terminate()
        serverGone(process)
    }

    /// The server exited: fail what it was asked and let the next request start a new one.
    private func serverGone(_ process: Process) {
        let (orphans, waiters) = withState { () -> ([Any], [DispatchSemaphore]) in
            if self.child === process {
                self.child = nil
                self.toChild = nil
            }
            guard self.child == nil else { return ([], []) }
            let orphans = Array(self.pending.values), waiters = Array(self.hiddenWaiters.values)
            self.pending = [:]
            self.hiddenWaiters = [:]
            return (orphans, waiters)
        }
        waiters.forEach { $0.signal() }
        for id in orphans {
            replyRPCError(id: id, "The \(name) MCP server exited before answering. Try again to restart it.")
        }
    }

    /// Saves what the running server really says, and tells the agent about any list it was
    /// given from the cache that turned out different.
    private func refreshCache() {
        guard let initialize = withState({ self.serverInitialize }) else { return }
        let handshakeMessage = handshake.first.flatMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
        var fresh: [String: Any] = ["initialize": initialize]
        fresh["protocolVersion"] = (handshakeMessage?["params"] as? [String: Any])?["protocolVersion"]
        let capabilities = initialize["capabilities"] as? [String: Any] ?? [:]
        for list in cachedLists where capabilities[list.capability] != nil {
            let request: [String: Any] = ["jsonrpc": "2.0", "id": 0, "method": list.method, "params": [String: Any]()]
            if let result = hiddenRequest(request, timeout: 30)?["result"] {
                fresh[list.method] = result
            } else if list.method == "tools/list" {
                return
            }
        }
        let changed = withState { () -> Set<String> in
            let old = self.cache
            fresh["server/discover"] = self.discoverRefusal ?? old?["server/discover"]
            let changed = self.answeredFromCache.filter { !sameJSON(old?[$0], fresh[$0]) }
            self.cache = fresh
            self.answeredFromCache = []
            return Set(changed.compactMap { method in cachedLists.first { $0.method == method }?.changed })
        }
        if let data = try? JSONSerialization.data(withJSONObject: fresh, options: [.sortedKeys, .withoutEscapingSlashes]) {
            try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: cacheURL, options: .atomic)
        }
        for method in changed.sorted() {
            writeToAgent(["jsonrpc": "2.0", "method": method])
        }
    }

    /// A request of our own; its reply is consumed here, never shown to the agent.
    private func hiddenRequest(_ message: [String: Any], timeout: TimeInterval) -> [String: Any]? {
        var message = message
        let id = withState { () -> String in
            self.hiddenCounter += 1
            return "ht-lazy-\(self.hiddenCounter)"
        }
        message["id"] = id
        let semaphore = DispatchSemaphore(value: 0)
        withState { self.hiddenWaiters[id] = semaphore }
        guard sendToChild(message), semaphore.wait(timeout: .now() + timeout) == .success else {
            withState { self.hiddenWaiters[id] = nil }
            return nil
        }
        return withState { self.hiddenReplies.removeValue(forKey: id) }
    }

    // MARK: - Server → agent

    private func relayServerOutput(from pipe: Pipe, of process: Process) {
        defer { serverGone(process) }
        // A dup, so closing the stream doesn't close the Pipe's own descriptor twice.
        guard let stream = fdopen(dup(pipe.fileHandleForReading.fileDescriptor), "r") else { return }
        var buffer: UnsafeMutablePointer<CChar>?
        var capacity = 0
        defer { free(buffer); fclose(stream) }
        while getline(&buffer, &capacity, stream) > 0, let buffer {
            withState { self.lastActivity = Date() }
            handleServerLine(String(cString: buffer))
        }
    }

    private func handleServerLine(_ line: String) {
        guard let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let id = message["id"], message["method"] == nil else {
            // Notifications and the server's own requests go to the agent as they are.
            writeToAgent(line)
            return
        }
        let key = mcpRequestKey(id)
        let hiddenKey = id as? String
        let waiter = withState { () -> DispatchSemaphore? in
            self.pending[key] = nil
            if key == self.directInitializeID {
                self.directInitializeID = nil
                self.serverInitialize = message["result"] as? [String: Any]
            }
            if let discover = self.directDiscover, key == discover.key {
                self.directDiscover = nil
                self.discoverRefusal = message["error"].map { ["protocolVersion": discover.version as Any, "error": $0] }
            }
            guard let hiddenKey, let waiter = self.hiddenWaiters.removeValue(forKey: hiddenKey) else { return nil }
            self.hiddenReplies[hiddenKey] = message
            return waiter
        }
        if let waiter {
            waiter.signal()
            return
        }
        // A late reply to one of our own timed-out hidden requests is not the agent's to see.
        if let text = id as? String, text.hasPrefix("ht-lazy-") { return }
        writeToAgent(line)
    }

    // MARK: - Plumbing

    private func replyRPCError(id: Any, code: Int = -32603, _ text: String) {
        writeToAgent(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": text]])
    }

    /// False when no server is running or it has gone away.
    @discardableResult
    private func sendToChild(_ line: String) -> Bool {
        guard let handle = withState({ self.toChild }) else { return false }
        return (try? handle.write(contentsOf: Data(line.utf8))) != nil
    }

    @discardableResult
    private func sendToChild(_ message: [String: Any]) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return false }
        return sendToChild(String(decoding: data, as: UTF8.self) + "\n")
    }

    private func writeToAgent(_ line: String) {
        outputLock.lock()
        FileHandle.standardOutput.write(Data(line.utf8))
        outputLock.unlock()
    }

    private func writeToAgent(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message, options: .withoutEscapingSlashes) else { return }
        writeToAgent(String(decoding: data, as: UTF8.self) + "\n")
    }

    private func withState<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }
}

private func sameJSON(_ a: Any?, _ b: Any?) -> Bool {
    func encode(_ value: Any?) -> Data? {
        value.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys, .fragmentsAllowed]) }
    }
    return encode(a) == encode(b)
}
