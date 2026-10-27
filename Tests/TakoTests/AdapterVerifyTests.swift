import XCTest
@testable import Tako

final class AdapterVerifyTests: XCTestCase {
    /// `claude --mcp-config <configs...>` is variadic: `claude --mcp-config a.json "fix the bug"`
    /// reads the prompt as a config path (verified against claude 2.1.291). The `=` form does not.
    func testClaudeWrapperUsesNonVariadicMcpConfigForms() {
        let script = ClaudeAdapter.wrapperScript()
        XCTAssertTrue(script.contains(#"--mcp-config="$HT_DIR/mcp.json""#))
        XCTAssertTrue(script.contains(#"${LAZY:+--mcp-config="$LAZY"}"#))
        XCTAssertFalse(script.contains(#"--mcp-config ""#))
        XCTAssertTrue(script.contains(#""$@""#))
    }
}
