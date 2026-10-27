import Foundation

/// The JSON-RPC notification `ht mcp` writes to push a message into Claude Code's channel.
enum ChannelEvent {
    /// No meta: Claude Code already tags the event with the server's name, and a "source" key
    /// here repeated it (`<channel source="hyperterm" source="hyperterm">`).
    static func notification(_ message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "method": "notifications/claude/channel", "params": ["content": message]]
    }
}

/// The `ht mcp` side of channel delivery. Each message is acknowledged on the poll after it was
/// written to Claude's stdin pipe, so Tako records "delivered" only for what actually reached
/// Claude, and types anything unconfirmed instead. Acks ride on the next long-poll, so
/// confirming costs no extra request.
struct ChannelPoller {
    /// Written but not yet reported. Kept across a failed poll, so a hiccup doesn't lose them.
    private(set) var unreported: [String] = []

    func nextRequest() -> ControlRequest {
        var request = ControlRequest(cmd: .subscribe)
        request.acks = unreported
        return request
    }

    /// The poll succeeded: writes each message with `write`, then queues its id for the next poll.
    mutating func received(_ response: ControlResponse, write: ([String: Any]) -> Void) {
        unreported = []
        let ids = response.messageIDs ?? []
        for (index, message) in (response.messages ?? []).enumerated() {
            write(ChannelEvent.notification(message))
            if index < ids.count { unreported.append(ids[index]) }
        }
    }
}
