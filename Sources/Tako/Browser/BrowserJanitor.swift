import Foundation

/// Closes Chromium pages no browser session owns. A page can outlive its tile (closed while
/// Chromium was still creating it, a popup, a tab an agent's tools opened directly), and each
/// keeps a renderer process alive. Pages are told apart by the tag every browser sets on its own
/// page (`window.__tako`), read over the DevTools port, which listens on loopback only.
@MainActor
final class BrowserJanitor {
    static let shared = BrowserJanitor()

    private var ledger = Ledger()
    private var sweeping = false

    struct Target: Decodable {
        let id: String
        let type: String
        let url: String?
        let webSocketDebuggerUrl: String?
    }

    /// What the janitor remembers about each page between sweeps. Reading a tag opens a DevTools
    /// websocket, so a page is asked once and its answer kept: before this, every page whose
    /// address didn't match its browser's (a redirect, a trailing slash) was asked again every
    /// sweep, ~3,000 websockets in two days, each logging socket errors on close.
    struct Ledger {
        struct Page {
            var tag: String?
            /// Consecutive sweeps the page was found unowned.
            var unownedSweeps = 0
            var closeRequested = false
            /// Survived a close: its renderer was stopped and it is left alone from now on.
            var stuck = false
        }

        struct Actions: Equatable {
            var close: [String] = []
            var stopRenderer: [String] = []
        }

        private(set) var pages: [String: Page] = [:]

        /// Addresses compare without a trailing slash: Chromium lists `http://localhost:3000/`
        /// for a browser that asked for `http://localhost:3000`.
        static func normalized(_ url: String?) -> String {
            guard var url, !url.isEmpty else { return "" }
            while url.hasSuffix("/"), !url.hasSuffix("://") { url.removeLast() }
            return url
        }

        private static func ownedByAddress(_ target: Target, _ addresses: Set<String>) -> Bool {
            let url = normalized(target.url)
            return !url.isEmpty && addresses.contains(url)
        }

        /// Whether the page's tag must be read this sweep: only when its owner isn't already
        /// known to be live. A rename re-tags the page, so a remembered tag that is no longer a
        /// live label is read again before anything is closed.
        func needsTag(_ target: Target, labels: Set<String>, addresses: Set<String>) -> Bool {
            if Self.ownedByAddress(target, addresses) { return false }
            guard let page = pages[target.id] else { return true }
            if page.stuck { return false }
            return !labels.contains(page.tag ?? "")
        }

        mutating func record(tag: String?, for id: String) {
            pages[id, default: Page()].tag = tag
        }

        /// Decides this sweep's closes. A page is closed after two unowned sweeps in a row, so a
        /// page being created (not tagged yet) or a short-lived popup is left alone. A page still
        /// listed a sweep after its close is half-closed (its browser was torn down while CEF
        /// was closing it, which no later close request finishes): its renderer is stopped,
        /// which frees the memory, and it is never asked about again.
        mutating func conclude(_ targets: [Target], labels: Set<String>, addresses: Set<String>) -> Actions {
            let present = Set(targets.map(\.id))
            pages = pages.filter { present.contains($0.key) }
            var actions = Actions()
            for target in targets {
                var page = pages[target.id] ?? Page()
                defer { pages[target.id] = page }
                if Self.ownedByAddress(target, addresses) || labels.contains(page.tag ?? "") {
                    page.unownedSweeps = 0
                    page.closeRequested = false
                    continue
                }
                if page.stuck { continue }
                if page.closeRequested {
                    page.stuck = true
                    actions.stopRenderer.append(target.id)
                    continue
                }
                page.unownedSweeps += 1
                if page.unownedSweeps >= 2 {
                    page.closeRequested = true
                    actions.close.append(target.id)
                }
            }
            return actions
        }
    }

    /// `labels` are the live browsers' tags; `addresses` their pages, which also count as owned
    /// (an error page may not run the tag script).
    func sweep(keeping labels: Set<String>, addresses: Set<String>) {
        guard !sweeping, let list = URL(string: AgentBrowser.endpoint + "/json/list") else { return }
        sweeping = true
        let addresses = Set(addresses.map { Ledger.normalized($0) })
        Task {
            defer { sweeping = false }
            guard let data = try? await Self.fetch(list),
                  let all = try? JSONDecoder().decode([Target].self, from: data) else { return }
            let targets = all.filter { $0.type == "page" }
            for target in targets where ledger.needsTag(target, labels: labels, addresses: addresses) {
                ledger.record(tag: await Self.tag(of: target), for: target.id)
            }
            let actions = ledger.conclude(targets, labels: labels, addresses: addresses)
            for id in actions.close {
                if let close = URL(string: AgentBrowser.endpoint + "/json/close/" + id) { _ = try? await Self.fetch(close) }
            }
            for id in actions.stopRenderer {
                if let target = targets.first(where: { $0.id == id }) { await Self.stopRenderer(of: target) }
            }
        }
    }

    private nonisolated static func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        return try await URLSession.shared.data(for: request).0
    }

    /// The page's browser label, or nil when it has none (or doesn't answer in time).
    private nonisolated static func tag(of target: Target) async -> String? {
        let ask = #"{"id":1,"method":"Runtime.evaluate","params":{"expression":"window.__tako || ''","returnByValue":true}}"#
        guard let json = await devTools(target, ask) else { return nil }
        let value = ((json["result"] as? [String: Any])?["result"] as? [String: Any])?["value"] as? String
        return value?.isEmpty == false ? value : nil
    }

    /// Ends a half-closed page's renderer process. The page entry itself can't be removed from
    /// outside CEF, but the renderer is what holds the memory (~30 MB each).
    private nonisolated static func stopRenderer(of target: Target) async {
        _ = await devTools(target, #"{"id":1,"method":"Page.crash"}"#, awaitReply: false)
    }

    /// Sends one DevTools command to a page and returns its reply (id 1).
    private nonisolated static func devTools(_ target: Target, _ command: String, awaitReply: Bool = true) async -> [String: Any]? {
        guard let raw = target.webSocketDebuggerUrl, let url = URL(string: raw) else { return nil }
        let socket = URLSession.shared.webSocketTask(with: url)
        socket.resume()
        defer { socket.cancel(with: .goingAway, reason: nil) }
        do {
            try await socket.send(.string(command))
            guard awaitReply else { return nil }
            for _ in 0..<5 {
                guard case .string(let text) = try await socket.receive(),
                      let json = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                      json["id"] as? Int == 1 else { continue }
                return json
            }
        } catch {}
        return nil
    }
}
