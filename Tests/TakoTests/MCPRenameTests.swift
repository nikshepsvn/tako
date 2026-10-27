import XCTest
@testable import Tako

/// Tako's MCP server is `tako` (tools `mcp__tako__*`); what was saved or registered under the
/// old name `hyperterm` carries over.
final class MCPRenameTests: XCTestCase {
    func testAgentsGetTheServerAsTako() {
        XCTAssertTrue(SessionStore.sumiTools.allSatisfy { $0.hasPrefix("mcp__tako__") })
        let wrapper = CodexAdapter.wrapperScript(ht: "/Users/me/.tako/bin/ht")
        XCTAssertTrue(wrapper.contains("mcp_servers.tako.args"), wrapper)
        XCTAssertFalse(wrapper.contains("mcp_servers.hyperterm"), wrapper)
        XCTAssertTrue(ClaudeAdapter.wrapperScript().contains("server:tako"))
    }

    func testBothNamesAreReservedForTakosServer() {
        XCTAssertTrue(LazyMCP.reservedNames.isSuperset(of: ["tako", "hyperterm", "browser"]))
    }

    func testLearnedApprovalsMoveToTheNewToolNames() throws {
        let old = Date(timeIntervalSince1970: 1_000), new = Date(timeIntervalSince1970: 2_000)
        let json = """
        {"projects": {"/repo": {
          "mcp__hyperterm__send_message": {"approved": 3, "denied": 0, "always": true, "lastAt": "1970-01-01T00:16:40Z"},
          "mcp__hyperterm__start_agent": {"approved": 1, "denied": 0, "always": false, "lastAt": "1970-01-01T00:16:40Z"},
          "mcp__tako__start_agent": {"approved": 0, "denied": 2, "always": false, "lastAt": "1970-01-01T00:33:20Z"},
          "Bash(pnpm test)": {"approved": 1, "denied": 0, "always": false, "lastAt": "1970-01-01T00:16:40Z"}
        }}}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let memory = try decoder.decode(ApprovalMemory.self, from: Data(json.utf8))

        XCTAssertTrue(memory.allows(project: "/repo", key: "mcp__tako__send_message"))
        XCTAssertEqual(memory.record(project: "/repo", key: "mcp__tako__send_message")?.lastAt, old)
        // Learned under the new name already: that answer stands.
        XCTAssertEqual(memory.record(project: "/repo", key: "mcp__tako__start_agent")?.denied, 2)
        XCTAssertEqual(memory.record(project: "/repo", key: "mcp__tako__start_agent")?.lastAt, new)
        XCTAssertNotNil(memory.record(project: "/repo", key: "Bash(pnpm test)"))
        XCTAssertFalse(memory.projects["/repo"]!.keys.contains { $0.hasPrefix("mcp__hyperterm__") })

        // And it round-trips.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(ApprovalMemory.self, from: encoder.encode(memory)), memory)
    }

    // MARK: - Channels

    private func defaults() -> UserDefaults {
        let name = "tako-channels-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    @MainActor
    func testChannelsAreReRegisteredOnceAsTako() async {
        let defaults = defaults()
        let commands = Commands()
        let ran = await ChannelsMigration.runIfNeeded(defaults: defaults, channelsEnabled: true, isolated: false, htPath: "/Users/me/.tako/bin/ht",
                                                      run: { commands.append($0); return "" })
        XCTAssertTrue(ran)
        XCTAssertEqual(commands.all.count, 1)
        let command = commands.all[0]
        let remove = command.range(of: "claude mcp remove --scope user hyperterm")
        let add = command.range(of: "claude mcp add --scope user tako '/Users/me/.tako/bin/ht' mcp")
        XCTAssertNotNil(remove, command)
        XCTAssertNotNil(add, command)
        XCTAssertLessThan(remove!.lowerBound, add!.lowerBound)

        let again = await ChannelsMigration.runIfNeeded(defaults: defaults, channelsEnabled: true, isolated: false, htPath: "/x",
                                                        run: { commands.append($0); return "" })
        XCTAssertFalse(again)
        XCTAssertEqual(commands.all.count, 1)
    }

    @MainActor
    func testChannelsMigrationRetriesAfterAFailureAndSkipsWhenOff() async {
        let defaults = defaults()
        let commands = Commands()
        let off = await ChannelsMigration.runIfNeeded(defaults: defaults, channelsEnabled: false, isolated: false, htPath: "/x",
                                                      run: { commands.append($0); return "" })
        XCTAssertFalse(off)
        XCTAssertTrue(commands.all.isEmpty)

        let failed = await ChannelsMigration.runIfNeeded(defaults: defaults, channelsEnabled: true, isolated: false, htPath: "/x",
                                                         run: { commands.append($0); return nil })
        XCTAssertFalse(failed)
        XCTAssertFalse(defaults.bool(forKey: ChannelsMigration.doneKey))
        let retried = await ChannelsMigration.runIfNeeded(defaults: defaults, channelsEnabled: true, isolated: false, htPath: "/x",
                                                          run: { commands.append($0); return "" })
        XCTAssertTrue(retried)
        XCTAssertEqual(commands.all.count, 2)
    }

    /// A copy on its own data must leave Claude's (Mac-wide) config alone, or it points the
    /// user's `tako` server at its own throwaway ht.
    @MainActor
    func testAnIsolatedCopyNeverRewritesClaudesConfig() async {
        let suite = self.defaults()
        let commands = Commands()
        let ran = await ChannelsMigration.runIfNeeded(defaults: suite, channelsEnabled: true, isolated: true,
                                                      htPath: "/Users/me/.tako-mem/bin/ht",
                                                      run: { commands.append($0); return "" })
        XCTAssertFalse(ran)
        XCTAssertTrue(commands.all.isEmpty)
        XCTAssertFalse(suite.bool(forKey: ChannelsMigration.doneKey))
    }
}

/// Commands a fake runner was handed, from whichever thread ran it.
private final class Commands: @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [String] = []
    func append(_ command: String) { lock.withLock { commands.append(command) } }
    var all: [String] { lock.withLock { commands } }

}
