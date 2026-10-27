import XCTest
@testable import Tako

final class MCPFixTests: XCTestCase {
    /// A stray `}` inside an array used to return without advancing, looping forever.
    func testMalformedArrayWithStrayBraceTerminates() {
        let toml = """
        [mcp_servers.bad]
        command = "x"
        args = ["a", }, "b"]
        [mcp_servers.after]
        command = "y"
        """
        let servers = LazyMCP.codexServers(toml)
        XCTAssertEqual(servers["bad"]?["command"] as? String, "x")
        XCTAssertEqual(servers["after"]?["command"] as? String, "y")
    }

    func testUnterminatedArrayTerminates() {
        let servers = LazyMCP.codexServers("[mcp_servers.a]\ncommand = \"x\"\nargs = [\"a\", }")
        XCTAssertEqual(servers["a"]?["command"] as? String, "x")
    }
}
