import Foundation

/// The JSON-RPC notification `ht mcp` writes to push a message into Claude Code's channel.
enum ChannelEvent {
    /// No meta: Claude Code already tags the event with the server's name, and a "source" key
    /// here repeated it (`<channel source="hyperterm" source="hyperterm">`).
    static func notification(_ message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "method": "notifications/claude/channel", "params": ["content": message]]
    }
}
