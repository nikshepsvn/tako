import XCTest
@testable import Hyperterm

/// Runtime efficiency and data hygiene: fixes driven by Tako's own logs.
final class RuntimeHygieneTests: XCTestCase {
    // MARK: - Foreground command label

    func testCommandLabelSkipsURLsAndShortensPaths() {
        XCTAssertEqual(ProcessInspector.commandLabel(argv: ["/usr/local/bin/npx", "-y", "mcp-remote", "https://mcp.example.com/sse"]),
                       "npx -y mcp-remote")
        XCTAssertEqual(ProcessInspector.commandLabel(argv: ["/opt/homebrew/bin/node", "/Users/me/app/server.js", "--port", "3000", "extra"]),
                       "node server.js --port 3000")
        XCTAssertEqual(ProcessInspector.commandLabel(argv: ["python3"]), "python3")
        XCTAssertEqual(ProcessInspector.commandLabel(argv: []), "")
    }
}
