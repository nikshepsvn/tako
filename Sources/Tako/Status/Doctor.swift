import Foundation

/// `ht doctor` (and Sumi's doctor tool): Tako's health on one screen, one ✓ or ! per line. The
/// last day comes from events.jsonl, the rest from what the app holds now. Pure, so every
/// threshold is testable; `SessionStore.doctor` gathers the inputs.
enum Doctor {
    static let window: TimeInterval = 24 * 3600
    /// More MCP helpers than this in one agent's tree is a leak, not configuration.
    static let helperLimit = 8
    /// Footprint growth over the window worth a look before it becomes a restart.
    static let growthLimit: UInt64 = 512 << 20
    static let noisyNotifications = 200

    struct Snapshot {
        var now = Date()
        var uptime: TimeInterval = 0
        var footprint: UInt64 = 0
        /// Banners shown and held back since the last hourly footprint line.
        var notifications = (sent: 0, suppressed: 0)
        var agents: [(label: String, kind: String, asleep: Bool)] = []
        var crashLooping: [String] = []
        /// Tako's MCP helpers (`ht mcp`, `ht mcp-lazy`, `ht browser-mcp`) per live agent.
        var helpers: [String: Int] = [:]
        var browser = (running: false, processes: 0, bytes: UInt64(0))
        /// Worktrees Tako made that are still on disk and no session uses.
        var idleWorktrees: [Date] = []
        var channels = Channels.off
    }

    enum Channels: Equatable {
        case off
        case registered
        case missing
        /// Registered, but not as `tako ht mcp` (the old `hyperterm` name, or another binary).
        case wrong(String)
    }

    /// Whether Claude's user config registers Tako's channel server the way the wrapper asks
    /// for it (`server:tako`). Read-only: the fix is the user's (or Tako's migration's) to make.
    static func channels(enabled: Bool, claudeConfig: Data?, htPath: String) -> Channels {
        guard enabled else { return .off }
        guard let data = claudeConfig,
              let config = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .missing }
        let servers = config["mcpServers"] as? [String: Any] ?? [:]
        guard let tako = servers["tako"] as? [String: Any] else {
            return servers["hyperterm"] != nil ? .wrong("registered as \"hyperterm\", but Tako asks for server:tako") : .missing
        }
        let command = tako["command"] as? String ?? ""
        let args = tako["args"] as? [String] ?? []
        guard (command as NSString).lastPathComponent == "ht", args == ["mcp"] else {
            return .wrong("\"tako\" runs \(([command] + args).joined(separator: " ")), not ht mcp")
        }
        if command != htPath { return .wrong("\"tako\" runs \(command), not this Tako's \(htPath)") }
        return .registered
    }

    static func report(_ snapshot: Snapshot, events: [LoggedEvent]) -> String {
        let day = events.filter { snapshot.now.timeIntervalSince($0.date) <= window }
        var lines = ["Tako doctor · up \(SessionStore.duration(snapshot.uptime)) · \(size(snapshot.footprint))",
                     "Last 24 h (events.jsonl):"]
        lines += [hooks(day), messages(day), notifications(day, now: snapshot.notifications), launches(day), gc(day)]
        lines.append("Now:")
        lines += [footprint(snapshot, day), agents(snapshot), helpers(snapshot), browser(snapshot),
                  worktrees(snapshot), channels(snapshot.channels)]
        return lines.joined(separator: "\n")
    }

    private static func line(_ ok: Bool, _ text: String) -> String { (ok ? "✓ " : "! ") + text }

    static func size(_ bytes: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory) }

    private static func hooks(_ events: [LoggedEvent]) -> String {
        let failed = events.filter { $0.kind == "hook" }
        guard !failed.isEmpty else { return line(true, "hooks: none rejected or timed out") }
        let kinds = tally(failed.map { $0.text.replacingOccurrences(of: "answered ", with: "") })
        return line(false, "hooks: \(failed.count) rejected or timed out (" + kinds.prefix(3).map { "\($0.1)× \($0.0)" }.joined(separator: ", ") + ")")
    }

    private static func messages(_ events: [LoggedEvent]) -> String {
        let messages = events.filter { $0.kind == "message" }
        func count(_ outcome: String) -> Int { messages.filter { $0.string("outcome") == outcome }.count }
        let delivered = count("delivered"), dropped = count("dropped"), stale = count("still queued"), unconfirmed = count("not confirmed")
        var text = "messages: \(delivered) delivered from a queue or channel"
        guard dropped + stale + unconfirmed > 0 else { return line(true, text + ", none dropped or unconfirmed") }
        if dropped > 0 { text += ", \(dropped) dropped (" + labelList(tally(messages.filter { $0.string("outcome") == "dropped" }.compactMap(\.session)).map(\.0), limit: 3) + ")" }
        if stale > 0 { text += ", \(stale) queued over an hour" }
        if unconfirmed > 0 { text += ", \(unconfirmed) channel pushes not confirmed (typed instead)" }
        return line(dropped + unconfirmed == 0, text)
    }

    private static func notifications(_ events: [LoggedEvent], now: (sent: Int, suppressed: Int)) -> String {
        let hourly = events.filter { $0.kind == "footprint" && $0.int("notified") != nil }
        let sent = hourly.reduce(now.sent) { $0 + ($1.int("notified") ?? 0) }
        let suppressed = hourly.reduce(now.suppressed) { $0 + ($1.int("suppressed") ?? 0) }
        return line(sent <= noisyNotifications, "notifications: \(sent) sent, \(suppressed) suppressed (repeats, flapping, in view)"
            + (sent > noisyNotifications ? "; noisy" : ""))
    }

    /// Leftovers stopped at each launch: a clean quit leaves none.
    private static func launches(_ events: [LoggedEvent]) -> String {
        var perLaunch: [Int] = []
        for event in events {
            if event.kind == "launch" { perLaunch.append(0) }
            else if event.kind == "sweep" {
                if perLaunch.isEmpty { perLaunch.append(0) }
                perLaunch[perLaunch.count - 1] += 1
            }
        }
        let swept = perLaunch.reduce(0, +)
        let launches = "launches: \(events.filter { $0.kind == "launch" }.count)"
        guard swept > 0 else { return line(true, "\(launches); no leftover processes to sweep") }
        return line(false, "\(launches); leftovers stopped per launch: " + perLaunch.map(String.init).joined(separator: ", ")
            + " (the run before didn't clean up)")
    }

    private static func gc(_ events: [LoggedEvent]) -> String {
        let gc = events.filter { $0.kind == "gc" }
        let troubled = gc.filter { event in ["couldn't", "failed", "skipped"].contains { event.text.contains($0) } }
        guard !gc.isEmpty else { return line(true, "gc: nothing to do") }
        var text = "gc: \(gc.count) action\(gc.count == 1 ? "" : "s")"
        if let first = troubled.last { text += ", \(troubled.count) not done (last: \(SessionStore.clip(first.text, 70)))" }
        return line(troubled.isEmpty, text)
    }

    private static func footprint(_ snapshot: Snapshot, _ events: [LoggedEvent]) -> String {
        let readings = events.filter { $0.kind == "footprint" }.compactMap { event in event.double("footprint").map { UInt64($0) } }
        var text = "footprint \(size(snapshot.footprint))"
        var ok = snapshot.footprint < FootprintTrend.highWater
        if let first = readings.first {
            let peak = max(readings.max() ?? 0, snapshot.footprint)
            text += " (24 h: \(size(first)) → \(size(snapshot.footprint)), peak \(size(peak)))"
            if snapshot.footprint > first + growthLimit { ok = false; text += ", growing" }
        }
        if events.contains(where: { $0.kind == "footprint" && $0.fields["breakdown"] != nil }) {
            text += "; breakdown in events.jsonl"
        }
        return line(ok, text)
    }

    private static func agents(_ snapshot: Snapshot) -> String {
        let kinds = tally(snapshot.agents.map(\.kind)).map { "\($0.1) \($0.0)" }.joined(separator: ", ")
        let asleep = snapshot.agents.filter(\.asleep).count
        var text = "agents: \(snapshot.agents.count) live" + (kinds.isEmpty ? "" : " (\(kinds))") + (asleep > 0 ? ", \(asleep) asleep" : "")
        if !snapshot.crashLooping.isEmpty { text += "; CRASH-LOOPING: " + labelList(snapshot.crashLooping) }
        return line(snapshot.crashLooping.isEmpty, text)
    }

    private static func helpers(_ snapshot: Snapshot) -> String {
        guard !snapshot.helpers.isEmpty else { return line(true, "MCP helpers: none running") }
        let counts = snapshot.helpers.values.sorted()
        let over = snapshot.helpers.filter { $0.value > helperLimit }.sorted { $0.value > $1.value }
        guard !over.isEmpty else {
            return line(true, "MCP helpers: \(counts.first ?? 0)–\(counts.last ?? 0) per agent, \(counts.reduce(0, +)) in all")
        }
        return line(false, "MCP helpers: " + over.prefix(3).map { "@\($0.key) \($0.value)" }.joined(separator: ", ")
            + " (over \(helperLimit); others ≤ \(snapshot.helpers.filter { $0.value <= helperLimit }.values.max() ?? 0))")
    }

    private static func browser(_ snapshot: Snapshot) -> String {
        guard snapshot.browser.running else { return line(true, "browser (CEF): not started") }
        return line(true, "browser (CEF): running, \(snapshot.browser.processes) processes, \(size(snapshot.browser.bytes))")
    }

    private static func worktrees(_ snapshot: Snapshot) -> String {
        guard let oldest = snapshot.idleWorktrees.min() else { return line(true, "worktrees: none waiting for gc") }
        let age = snapshot.now.timeIntervalSince(oldest)
        let stale = age > WorktreeJanitor.keepFor
        return line(!stale, "worktrees: \(snapshot.idleWorktrees.count) unused, waiting for gc (oldest made \(SessionStore.duration(age)) ago"
            + (stale ? "; past the 7-day keep: has uncommitted work or is locked?" : "") + ")")
    }

    private static func channels(_ state: Channels) -> String {
        switch state {
        case .off: return line(true, "channels: off (messages are typed)")
        case .registered: return line(true, "channels: on, registered as tako in ~/.claude.json")
        case .missing: return line(false, "channels: on, but ~/.claude.json has no \"tako\" server: messages fall back to typing")
        case .wrong(let why): return line(false, "channels: on, but ~/.claude.json " + why)
        }
    }
}
