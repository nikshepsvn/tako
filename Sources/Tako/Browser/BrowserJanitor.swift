import Foundation

/// Closes Chromium pages no browser session owns. A page can outlive its tile (closed while
/// Chromium was still creating it, a popup, a tab an agent's tools opened directly), and each
/// keeps a renderer process alive. Pages are told apart by the tag every browser sets on its own
/// page (`window.__tako`), read over the DevTools port, which listens on loopback only.
@MainActor
final class BrowserJanitor {
    static let shared = BrowserJanitor()

    /// Pages found unowned last sweep: closed only when still unowned on the next, so a page
    /// being created (not tagged yet) or a short-lived popup is left alone.
    private var suspects: Set<String> = []
    private var sweeping = false

    struct Target: Decodable {
        let id: String
        let type: String
        let url: String?
        let webSocketDebuggerUrl: String?
    }

    /// `labels` are the live browsers' tags; `addresses` their pages, which also count as owned
    /// (an error page may not run the tag script).
    func sweep(keeping labels: Set<String>, addresses: Set<String>) {
        guard !sweeping, let list = URL(string: AgentBrowser.endpoint + "/json/list") else { return }
        sweeping = true
        Task {
            let targets = (try? await Self.fetch(list)).flatMap { try? JSONDecoder().decode([Target].self, from: $0) } ?? []
            var unowned: Set<String> = []
            for target in targets where target.type == "page" && !addresses.contains(target.url ?? "") {
                let tag = await Self.tag(of: target)
                if !labels.contains(tag ?? "") { unowned.insert(target.id) }
            }
            for id in unowned.intersection(suspects) {
                if let close = URL(string: AgentBrowser.endpoint + "/json/close/" + id) { _ = try? await Self.fetch(close) }
            }
            suspects = unowned.subtracting(suspects)
            sweeping = false
        }
    }

    private nonisolated static func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        return try await URLSession.shared.data(for: request).0
    }

    /// The page's browser label, or nil when it has none (or doesn't answer in time).
    private nonisolated static func tag(of target: Target) async -> String? {
        guard let raw = target.webSocketDebuggerUrl, let url = URL(string: raw) else { return nil }
        let socket = URLSession.shared.webSocketTask(with: url)
        socket.resume()
        defer { socket.cancel(with: .goingAway, reason: nil) }
        let ask = #"{"id":1,"method":"Runtime.evaluate","params":{"expression":"window.__tako || ''","returnByValue":true}}"#
        do {
            try await socket.send(.string(ask))
            for _ in 0..<5 {
                guard case .string(let text) = try await socket.receive(),
                      let json = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                      json["id"] as? Int == 1 else { continue }
                let value = ((json["result"] as? [String: Any])?["result"] as? [String: Any])?["value"] as? String
                return value?.isEmpty == false ? value : nil
            }
        } catch {}
        return nil
    }
}
