import AppKit

/// Browsers are sessions: each agent gets its own on its first browser action, and the user can
/// open more. Like terminals they get the next short name (@charlie); the owner is recorded.
extension SessionStore {
    /// The agent's browser, created (in the background) the first time it's needed.
    func browser(for agent: TerminalSession) -> TerminalSession {
        if let existing = browsers(ownedBy: agent).first { return existing }
        var spec = LaunchSpec(label: "", kind: .browser, cwd: agent.spec.cwd)
        spec.owner = agent.id
        let browser = create(spec, select: false)
        agent.record(.note, "Opened browser @\(browser.label)")
        return browser
    }

    /// A browser the user opened, on the selected terminal's dev server when it has one.
    @discardableResult
    func openBrowser(url: URL? = nil) -> TerminalSession {
        let current = selected
        let port = current?.ports.first ?? sessions.first { $0.kind == .server && !$0.ports.isEmpty }?.ports.first
        var spec = LaunchSpec(label: "", kind: .browser, cwd: current?.spec.cwd ?? NSHomeDirectory())
        spec.url = (url ?? port.flatMap { URL(string: "http://localhost:\($0)") })?.absoluteString
        if let agent = current, agent.kind.isAgent, browsers(ownedBy: agent).isEmpty {
            spec.owner = agent.id
        }
        return create(spec)
    }

    /// Re-tags every browser's page so agents' tools can map pages to labels.
    func markBrowsers() {
        for session in sessions where session.kind == .browser {
            (session.surface as? BrowserSurfaceView)?.mark()
        }
    }

    /// Agents can use a browser that isn't on screen: create its page now.
    func wakeBrowser(_ session: TerminalSession) {
        (session.surface as? BrowserSurfaceView)?.goLive()
    }

    /// How long a browser nobody can see stays open after its last use.
    static let browserIdleLimit: TimeInterval = 600

    /// Every couple of minutes: browsers off screen that their agent can't be using (asleep,
    /// exited) or that went unused past the limit close their page; Chromium pages no browser
    /// owns are closed.
    func tidyBrowsers(now: Date = Date()) {
        guard AgentBrowser.shared.isRunning else { return }
        var live: Set<String> = []
        var addresses: Set<String> = []
        for session in sessions where session.kind == .browser {
            guard let surface = session.surface as? BrowserSurfaceView, surface.isLive else { continue }
            let owner = session.spec.owner.flatMap { id in sessions.first { $0.id == id } }
            let ownerIdle: Bool
            if let owner, case .exited = owner.state { ownerIdle = true } else { ownerIdle = owner?.isAsleep ?? false }
            if surface.isOffScreen, ownerIdle || now.timeIntervalSince(surface.lastUsedAt) > Self.browserIdleLimit {
                surface.goDormant()
                session.record(.note, "Page closed to save memory; it reopens when shown or used")
            } else {
                live.insert(session.label)
                if let url = surface.model.url?.absoluteString { addresses.insert(url) }
            }
        }
        BrowserJanitor.shared.sweep(keeping: live, addresses: addresses)
    }

    func isBrowserReady(_ session: TerminalSession) -> Bool {
        (session.surface as? BrowserSurfaceView)?.model.browser != nil
    }
}
