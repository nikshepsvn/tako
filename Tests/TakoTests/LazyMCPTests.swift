import XCTest
@testable import Tako

/// The user's own MCP servers wrapped in `ht mcp-lazy`: the config rewrites, and the proxy itself
/// against a fake server (python3) in a temporary HT_HOME.
final class LazyMCPTests: XCTestCase {
    private let ht = "/Users/me/.tako/bin/ht"

    // MARK: - Claude

    func testClaudeStdioServersAreWrappedByNameAndOthersLeftToClaude() throws {
        let config: [String: Any] = [
            "mcpServers": [
                "blender": ["type": "stdio", "command": "uvx", "args": ["blender-mcp"], "env": [String: String]()],
                "chrome-devtools": ["command": "npx", "args": ["chrome-devtools-mcp@latest", "--browser-url=http://127.0.0.1:9222"]],
                "remote": ["type": "http", "url": "https://example.com/mcp"],
                "warm": ["command": "warm-server"],
                "browser": ["command": "someone-elses-browser"],
            ],
            "projects": [
                "/repo": [
                    "mcpServers": [
                        "db": ["type": "stdio", "command": "db-mcp", "env": ["DB_URL": "postgres://x", "TOKEN": "t"]],
                        "chrome-devtools": ["type": "sse", "url": "http://localhost:1/sse"],
                    ],
                    "disabledMcpServers": ["blender"],
                ],
            ],
        ]
        let servers = LazyMCP.claudeServers(config: config, projectPath: "/repo", ht: ht, eager: ["warm"])
        XCTAssertEqual(Set(servers.keys), ["db"], "local http overrides user stdio; disabled, eager, http and reserved are left alone")
        let db = try XCTUnwrap(servers["db"] as? [String: Any])
        XCTAssertEqual(db["command"] as? String, ht)
        XCTAssertEqual(db["args"] as? [String], ["mcp-lazy", "--name", "db", "--env-keys", "DB_URL,TOKEN", "--", "db-mcp"])
        XCTAssertEqual(db["env"] as? [String: String], ["DB_URL": "postgres://x", "TOKEN": "t"], "env passes through unchanged")

        let elsewhere = LazyMCP.claudeServers(config: config, projectPath: "/other", ht: ht, eager: [])
        XCTAssertEqual(Set(elsewhere.keys), ["blender", "chrome-devtools", "warm"])
        XCTAssertEqual((elsewhere["chrome-devtools"] as? [String: Any])?["args"] as? [String],
                       ["mcp-lazy", "--name", "chrome-devtools", "--", "npx", "chrome-devtools-mcp@latest", "--browser-url=http://127.0.0.1:9222"])
    }

    // MARK: - Codex

    func testCodexStdioServersBecomeConfigOverrides() {
        let toml = """
        model = "gpt-5"
        [mcp_servers.blender]
        command = "uvx"
        args = ["blender-mcp"] # trailing comment

        [mcp_servers.docs]
        command = 'npx'
        args = [
          "-y",
          "docs \\"mcp\\"",
        ]
        env = { API_KEY = "k" }

        [mcp_servers.docs.env]
        REGION = "eu"

        [mcp_servers.remote]
        url = "https://example.com/mcp"

        [mcp_servers.off]
        command = "off"
        enabled = false

        [mcp_servers.warm]
        command = "warm"

        [profiles.fast]
        command = "not-a-server"
        """
        let overrides = LazyMCP.codexOverrides(configTOML: toml, ht: ht, eager: ["warm"])
        XCTAssertEqual(overrides, [
            "-c", "mcp_servers.blender.command=\"\(ht)\"",
            "-c", "mcp_servers.blender.args=[\"mcp-lazy\",\"--name\",\"blender\",\"--\",\"uvx\",\"blender-mcp\"]",
            "-c", "mcp_servers.docs.command=\"\(ht)\"",
            "-c", "mcp_servers.docs.args=[\"mcp-lazy\",\"--name\",\"docs\",\"--env-keys\",\"API_KEY,REGION\",\"--\",\"npx\",\"-y\",\"docs \\\"mcp\\\"\"]",
        ])
    }

    // MARK: - Cache key

    func testCacheKeyFollowsCommandArgumentsAndEnvValues() {
        let base = LazyMCP.cacheKey(command: "npx", arguments: ["a", "b"], environment: ["K": "1", "J": "2"])
        XCTAssertEqual(base, LazyMCP.cacheKey(command: "npx", arguments: ["a", "b"], environment: ["J": "2", "K": "1"]))
        XCTAssertEqual(base.count, 64)
        XCTAssertNotEqual(base, LazyMCP.cacheKey(command: "npx", arguments: ["a b"], environment: ["K": "1", "J": "2"]))
        XCTAssertNotEqual(base, LazyMCP.cacheKey(command: "npx", arguments: ["a", "b"], environment: ["K": "1", "J": "3"]))
        XCTAssertNotEqual(base, LazyMCP.cacheKey(command: "uvx", arguments: ["a", "b"], environment: ["K": "1", "J": "2"]))
    }

    // MARK: - Proxy round trip

    private static let fakeServer = """
    import json, os, sys
    log, tools = sys.argv[1], sys.argv[2]
    open(log, "a").write("start\\n")
    for line in sys.stdin:
        m = json.loads(line)
        if "id" not in m: continue
        method, r = m.get("method"), {}
        if method == "server/discover":
            print(json.dumps({"jsonrpc": "2.0", "id": m["id"], "error": {"code": -32602, "message": "Invalid request parameters"}}), flush=True)
            continue
        if method == "initialize":
            r = {"protocolVersion": m["params"]["protocolVersion"], "capabilities": {"tools": {}}, "serverInfo": {"name": "fake", "version": "1"}}
        elif method == "tools/list":
            r = {"tools": [{"name": n, "inputSchema": {"type": "object"}} for n in open(tools).read().split()]}
        elif method == "tools/call":
            r = {"content": [{"type": "text", "text": "called " + m["params"]["name"]}]}
        print(json.dumps({"jsonrpc": "2.0", "id": m["id"], "result": r}), flush=True)
    """

    func testProxyAnswersFromCacheAndStartsTheServerOnFirstCall() throws {
        let htBinary = try XCTUnwrap(Bundle.main.resourceURL?.appendingPathComponent("bin/ht").path)
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: htBinary) && FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lazy-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("server.py"), log = dir.appendingPathComponent("starts.log"), tools = dir.appendingPathComponent("tools")
        try Self.fakeServer.write(to: script, atomically: true, encoding: .utf8)
        try "probe".write(to: tools, atomically: true, encoding: .utf8)
        let arguments = ["mcp-lazy", "--name", "fake", "--", "/usr/bin/python3", script.path, log.path, tools.path]
        func starts() -> Int { ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").count }

        // First use: no cache, so the server starts at once and the cache is written.
        let first = try MCPTestClient(ht: htBinary, arguments: arguments, home: dir)
        _ = try first.handshake()
        XCTAssertEqual(try first.request("tools/list").toolNames, ["probe"])
        let cacheDir = dir.appendingPathComponent("mcp-cache")
        try waitUntil { ((try? FileManager.default.contentsOfDirectory(atPath: cacheDir.path)) ?? []).filter { $0.hasSuffix(".json") }.count == 1 }
        first.close()
        XCTAssertEqual(starts(), 1)

        // With the cache: the handshake and tools/list start nothing.
        let second = try MCPTestClient(ht: htBinary, arguments: arguments, home: dir)
        let initialize = try second.handshake()
        XCTAssertEqual(((initialize["result"] as? [String: Any])?["serverInfo"] as? [String: Any])?["name"] as? String, "fake")
        XCTAssertEqual(try second.request("tools/list").toolNames, ["probe"])
        XCTAssertNotNil(try second.request("ping")["result"] as? [String: Any])
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(second.children(), [], "nothing is spawned before the first call")
        XCTAssertEqual(starts(), 1)

        // The first call starts exactly one server and is answered by it.
        XCTAssertEqual(try second.call("probe"), "called probe")
        XCTAssertEqual(second.children().count, 1)
        XCTAssertEqual(try second.call("probe"), "called probe")
        XCTAssertEqual(second.children().count, 1)
        XCTAssertEqual(starts(), 2)
        XCTAssertNil(second.notification("notifications/tools/list_changed", timeout: 1), "same tools, no change announced")
        second.close()

        // The tools changed since the cache was written: the agent is told once the server runs.
        try "probe extra".write(to: tools, atomically: true, encoding: .utf8)
        let third = try MCPTestClient(ht: htBinary, arguments: arguments, home: dir)
        _ = try third.handshake()
        XCTAssertEqual(try third.request("tools/list").toolNames, ["probe"], "stale until the server starts")
        XCTAssertEqual(try third.call("extra"), "called extra")
        XCTAssertNotNil(third.notification("notifications/tools/list_changed", timeout: 10))
        XCTAssertEqual(try third.request("tools/list").toolNames, ["probe", "extra"])
        third.close()
    }

    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { throw CocoaError(.fileReadUnknown, userInfo: [NSDebugDescriptionErrorKey: "timed out"]) }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
}

/// An MCP client over `ht mcp-lazy`'s stdio.
private final class MCPTestClient: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var messages: [[String: Any]] = []
    private var nextID = 1

    init(ht: String, arguments: [String], home: URL) throws {
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: ht)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["HT_HOME"] = home.path
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.lock.lock()
            self.buffer.append(data)
            while let newline = self.buffer.firstIndex(of: 0x0a) {
                let line = self.buffer[..<newline]
                self.buffer.removeSubrange(...newline)
                if let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { self.messages.append(message) }
            }
            self.lock.unlock()
        }
        try process.run()
    }

    /// As Claude Code 2.1 does: a server/discover probe, then the initialize handshake.
    func handshake() throws -> [String: Any] {
        let probe = try request("server/discover", ["_meta": ["io.modelcontextprotocol/protocolVersion": "2026-07-28"]])
        XCTAssertEqual((probe["error"] as? [String: Any])?["code"] as? Int, -32602)
        let reply = try request("initialize", ["protocolVersion": "2025-06-18", "capabilities": [String: Any](),
                                               "clientInfo": ["name": "test", "version": "1"]])
        send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        return reply
    }

    func request(_ method: String, _ params: [String: Any] = [:]) throws -> [String: Any] {
        let id = nextID
        nextID += 1
        send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        return try XCTUnwrap(wait(timeout: 20) { $0["id"] as? Int == id }, "no reply to \(method)")
    }

    func call(_ tool: String) throws -> String? {
        let reply = try request("tools/call", ["name": tool, "arguments": [String: Any]()])
        return ((reply["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String
    }

    func notification(_ method: String, timeout: TimeInterval) -> [String: Any]? {
        wait(timeout: timeout) { $0["method"] as? String == method }
    }

    func children() -> [Int32] {
        let pgrep = Process(), output = Pipe()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-P", String(process.processIdentifier)]
        pgrep.standardOutput = output
        try? pgrep.run()
        pgrep.waitUntilExit()
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").compactMap { Int32($0) }
    }

    func close() {
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
    }

    private func send(_ message: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: message)
        input.fileHandleForWriting.write(data + Data("\n".utf8))
    }

    private func wait(timeout: TimeInterval, _ match: ([String: Any]) -> Bool) -> [String: Any]? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock()
            let index = messages.firstIndex(where: match)
            let found = index.map { messages.remove(at: $0) }
            lock.unlock()
            if let found { return found }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return nil
    }
}

private extension Dictionary where Key == String, Value == Any {
    var toolNames: [String] {
        ((self["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
    }
}
