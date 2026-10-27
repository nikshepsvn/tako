import AppKit
import CCefAppKit
import CefSwiftUI
import Observation

/// Tako's Chromium runtime, shared by every browser session. It starts on first use (a
/// browser session opening, or an agent's first browser tool call), never at app launch.
///
/// Agents drive browsers through `chrome-devtools-mcp` attached to Chromium's DevTools port,
/// which listens on loopback only. One profile in ~/.tako/browser holds every browser's
/// logins, separate from the user's own Chrome.
@MainActor @Observable
final class AgentBrowser {
    static let shared = AgentBrowser()

    /// Named in agents' MCP config before Chromium runs. If something else holds it, Chromium
    /// takes the next free port and agents' tools follow (the `browser` reply carries it).
    nonisolated static var preferredPort: Int {
        let stored = UserDefaults.standard.integer(forKey: "browserPort")
        return stored > 0 ? stored : 9339
    }
    /// The port Chromium actually listens on once started.
    private(set) static var port = preferredPort
    static var endpoint: String { "http://127.0.0.1:\(port)" }
    static var profileDirectory: URL { ControlPaths.supportDirectory.appendingPathComponent("browser") }

    /// Opt-in: agents may also use the user's own Chrome (Claude in Chrome). Off by default so
    /// agents stay inside Tako's browsers.
    nonisolated static var agentsMayUseOutsideChrome: Bool {
        get { UserDefaults.standard.bool(forKey: "agentsUseOutsideChrome") }
        set { UserDefaults.standard.set(newValue, forKey: "agentsUseOutsideChrome") }
    }

    private(set) var startError: String?
    /// The latest agent action on a browser ("@api · click"), shown in that browser's bar.
    private(set) var activity: Activity?
    @ObservationIgnored private var activityGeneration = 0

    struct Activity: Equatable {
        let agent: String
        let browser: String
        let action: String
    }

    var isRunning: Bool { CefRuntime.shared.isInitialized }

    /// Starts Chromium if needed. Returns false (with `startError`) when it can't.
    @discardableResult
    func start() -> Bool {
        if isRunning { return true }
        if startError != nil { return false }
        guard let free = (Self.preferredPort..<Self.preferredPort + 40).first(where: { !Self.portIsTaken($0) }) else {
            startError = "No free port for the browser near \(Self.preferredPort)."
            return false
        }
        Self.port = free
        var configuration = CefConfiguration()
        configuration.rootCachePath = Self.profileDirectory
        configuration.remoteDebuggingPort = Self.port
        configuration.persistSessionCookies = true
        configuration.extraCommandLineSwitches = Self.chromiumSwitches
        Self.pruneComponentDownloads(in: Self.profileDirectory)
        do {
            try CefRuntime.shared.initialize(configuration: configuration)
            CEFApplication.setTerminateHandler {
                ObjCBool(MainActor.assumeIsolated { (NSApp.delegate as? AppDelegate)?.terminateWithBrowsers() ?? true })
            }
            return true
        } catch {
            startError = String(describing: error)
            return false
        }
    }

    /// HTTP cache cap. Unbounded, the profile grew to ~400 MB (142 MB of it HTTP cache); pages
    /// agents load are mostly local dev servers that gain little from a big cache.
    static let diskCacheBytes = 96 * 1024 * 1024

    static var chromiumSwitches: [String: String?] {
        [
            // Past a handful of renderers, pages share processes instead of each starting one
            // (every agent can have tabs open), and no idle spare renderer is kept warm.
            "renderer-process-limit": "6",
            "disable-features": "SpareRendererForSitePerProcess",
            "disk-cache-size": String(diskCacheBytes),
            // Chrome's component updater downloads DRM, on-device models, TTS and safety lists
            // (~120 MB) that a browser for local dev and agents doesn't use.
            "disable-component-update": String?.none,
        ]
    }

    /// The component updater's download cache, left from before updates were turned off.
    /// Only that cache: cookies, logins and site storage live elsewhere in the profile.
    static func pruneComponentDownloads(in profile: URL) {
        try? FileManager.default.removeItem(at: profile.appendingPathComponent("component_crx_cache"))
    }

    /// Called for each browser tool an agent runs; clears itself a few seconds after the last one.
    func noteActivity(agent: String, browser: String, tool: String) {
        activity = Activity(agent: agent, browser: browser, action: tool.replacingOccurrences(of: "_", with: " "))
        activityGeneration += 1
        let generation = activityGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.activityGeneration == generation else { return }
            self.activity = nil
        }
    }

    // MARK: - Readiness

    /// Calls back once `isReady` holds and the DevTools endpoint answers, or false after ~10s.
    static func waitUntilReady(_ isReady: @escaping @MainActor () -> Bool, attempts: Int = 50,
                               _ completion: @escaping @MainActor (Bool) -> Void) {
        guard let url = URL(string: endpoint + "/json/version") else { completion(false); return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        URLSession.shared.dataTask(with: request) { _, response, _ in
            let answered = (response as? HTTPURLResponse)?.statusCode == 200
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if answered && isReady() { completion(true); return }
                    guard attempts > 1 else { completion(false); return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        MainActor.assumeIsolated { waitUntilReady(isReady, attempts: attempts - 1, completion) }
                    }
                }
            }
        }.resume()
    }

    /// Something else already listening on our port would receive the agents' CDP traffic.
    private static func portIsTaken(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }
}
