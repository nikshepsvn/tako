import XCTest
@testable import Hyperterm

/// Agents Tako starts use its `browser` server, so Claude's own browser plugins stay off in them.
final class BrowserPluginTests: XCTestCase {
    /// Off even when the user's own settings have it off (a project can still turn it on), and
    /// a copy installed from another marketplace too.
    func testTakoAgentsAlwaysDropTheOfficialBrowserPlugin() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("plugins-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude/plugins"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        XCTAssertEqual(ClaudeAdapter.duplicateBrowserPlugins(home: home), ["chrome-devtools-mcp@claude-plugins-official"])
        let installed = #"{"version": 2, "plugins": {"playwright@other": [], "stripe@claude-plugins-official": []}}"#
        try Data(installed.utf8).write(to: home.appendingPathComponent(".claude/plugins/installed_plugins.json"))
        let settings = #"{"enabledPlugins": {"chrome-devtools-mcp@claude-plugins-official": false}}"#
        try Data(settings.utf8).write(to: home.appendingPathComponent(".claude/settings.json"))
        XCTAssertEqual(ClaudeAdapter.duplicateBrowserPlugins(home: home),
                       ["chrome-devtools-mcp@claude-plugins-official", "playwright@other"])
    }

    func testGeneratedSettingsTurnThePluginOff() throws {
        try XCTSkipIf(AgentBrowser.agentsMayUseOutsideChrome, "the user lets agents use their own Chrome")
        let data = Data(ClaudeAdapter.settings(hookPort: 1234).utf8)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let plugins = try XCTUnwrap(json["enabledPlugins"] as? [String: Bool])
        XCTAssertEqual(plugins["chrome-devtools-mcp@claude-plugins-official"], false)
        XCTAssertNotNil(json["hooks"])
    }
}
