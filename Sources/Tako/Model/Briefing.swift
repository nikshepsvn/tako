import Foundation

/// `standup since`: what happened while the user was away, ahead of the usual standup. Built
/// from events.jsonl (which outlives a restart of Tako) and what the store holds now (turns
/// finished, waits and queues still open), and kept to a dozen lines or so: it is read on a phone.
enum Briefing {
    /// The longest a briefing looks back, whatever it is asked: the log holds about that much.
    static let maxLookback: TimeInterval = 7 * 86_400
    /// With since "last" and no standup on record.
    static let defaultLookback: TimeInterval = 8 * 3600

    /// What the store knows now, gathered on the main actor.
    struct Live {
        /// Agents that finished turns since, with how many and the last one's summary.
        var finished: [(label: String, turns: Int, last: String?)] = []
        /// Agents waiting on the user this moment.
        var waitingOnUser: [String] = []
        /// Messages still queued, by target label.
        var queued: [(label: String, count: Int)] = []
        /// Steward warnings still open.
        var escalations: [String] = []
    }

    /// `since` as Sumi wrote it: "last" (its previous standup), a duration ("8h", "90m", "2d")
    /// or an ISO time ("2026-10-27T08:00:00Z", or local "2026-10-27T08:00"). Nil for anything else.
    static func start(_ raw: String, last: Date?, now: Date) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespaces).lowercased()
        let start: Date?
        if text == "last" {
            start = last ?? now.addingTimeInterval(-defaultLookback)
        } else if let unit = text.last, let amount = Double(text.dropLast()), amount >= 0,
                  let seconds = ["s": 1.0, "m": 60, "h": 3600, "d": 86_400][unit] {
            start = now.addingTimeInterval(-amount * seconds)
        } else {
            start = parseTime(raw.trimmingCharacters(in: .whitespaces))
        }
        return start.map { max($0, now.addingTimeInterval(-maxLookback)) }
    }

    private static func parseTime(_ text: String) -> Date? {
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: text) { return date }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: text) { return date }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            local.dateFormat = format
            if let date = local.date(from: text) { return date }
        }
        return nil
    }

    static func describe(since: Date, now: Date, events: [LoggedEvent], live: Live) -> String {
        let ago = SessionStore.duration(now.timeIntervalSince(since))
        var lines = ["Since \(stamp(since, now: now)) (\(ago) ago):"]
        lines += agentLines(events, live: live)
        if let plan = planLine(events) { lines.append(plan) }
        if let approvals = approvalLine(events, live: live) { lines.append(approvals) }
        if let messages = messageLine(events, live: live) { lines.append(messages) }
        if let steward = stewardLine(events, live: live) { lines.append(steward) }
        if lines.count == 1 { lines.append("- nothing happened") }
        return lines.joined(separator: "\n")
    }

    private static func agentLines(_ events: [LoggedEvent], live: Live) -> [String] {
        var lines: [String] = []
        let agent = events.filter { $0.kind == "agent" }
        func labels(_ action: String) -> [String] { agent.filter { $0.string("action") == action }.compactMap(\.session) }
        let started = labels("started"), restarted = labels("restarted")
        if !started.isEmpty || !restarted.isEmpty {
            var line = "- started \(started.count)" + (started.isEmpty ? "" : ": " + labelList(started))
            if !restarted.isEmpty { line += "; restarted \(restarted.count): " + labelList(Array(Set(restarted)).sorted()) }
            lines.append(line)
        }
        if !live.finished.isEmpty {
            let turns = live.finished.reduce(0) { $0 + $1.turns }
            let busiest = live.finished.sorted { $0.turns > $1.turns }
            var line = "- finished \(turns) turn\(turns == 1 ? "" : "s"): "
                + busiest.prefix(4).map { "@\($0.label) \($0.turns)" }.joined(separator: ", ")
                + (busiest.count > 4 ? " +\(busiest.count - 4)" : "")
            if let last = busiest.first?.last { line += " (@\(busiest[0].label) last: \(SessionStore.clip(last, 80)))" }
            lines.append(line)
        }
        let stops = agent.filter { ["failed", "exited"].contains($0.string("action") ?? "") && $0.int("code") != 0 }
        if !stops.isEmpty {
            let recent: [String] = stops.suffix(3).map { event in
                let what = SessionStore.clip(event.text, 50)
                return "@\(event.session ?? "?") \(what) \(clock(event.date))"
            }
            let earlier = stops.count > 3 ? "; +\(stops.count - 3) earlier" : ""
            lines.append("- FAILED or exited \(stops.count): " + recent.joined(separator: "; ") + earlier)
        }
        return lines
    }

    private static func planLine(_ events: [LoggedEvent]) -> String? {
        let plan = events.filter { $0.kind == "plan" }
        guard !plan.isEmpty else { return nil }
        var parts: [String] = []
        for status in ["done", "failed"] {
            let ids = plan.filter { $0.string("status") == status }.compactMap { $0.string("task") }
            if !ids.isEmpty { parts.append("\(ids.count) \(status) (" + ids.prefix(5).joined(separator: ", ") + (ids.count > 5 ? ", …" : "") + ")") }
        }
        return parts.isEmpty ? nil : "- plan: " + parts.joined(separator: ", ")
    }

    /// Auto-answered means Tako answered without the user: Phone Mode's ordinary requests and
    /// the ones the user always allows in that project.
    private static func approvalLine(_ events: [LoggedEvent], live: Live) -> String? {
        let approvals = events.filter { $0.kind == "approval" }
        let auto = approvals.filter { $0.string("outcome") == "phone-mode" || $0.string("by") == "auto" }.count
        let answered = approvals.filter { ["approved", "always", "denied"].contains($0.string("outcome") ?? "") && $0.string("by") != "auto" }.count
        let lapsed = approvals.filter { $0.string("outcome") == "released" }.count
        guard auto + answered + lapsed > 0 || !live.waitingOnUser.isEmpty else { return nil }
        var parts = ["\(auto) auto-answered", "\(answered) answered"]
        if lapsed > 0 { parts.append("\(lapsed) left to the CLI's own prompt") }
        var line = "- approvals: " + parts.joined(separator: ", ")
        line += live.waitingOnUser.isEmpty ? "; none waiting" : "; WAITING on the user now: " + labelList(live.waitingOnUser)
        return line
    }

    private static func messageLine(_ events: [LoggedEvent], live: Live) -> String? {
        let messages = events.filter { $0.kind == "message" }
        let delivered = messages.filter { $0.string("outcome") == "delivered" }.count
        let dropped = messages.filter { $0.string("outcome") == "dropped" }
        let unconfirmed = messages.filter { $0.string("outcome") == "not confirmed" }.count
        let queued = live.queued.reduce(0) { $0 + $1.count }
        guard delivered + dropped.count + unconfirmed + queued > 0 else { return nil }
        var line = "- messages: \(delivered) delivered"
        if !dropped.isEmpty {
            line += ", \(dropped.count) NOT delivered (" + labelList(tally(dropped.compactMap(\.session)).map(\.0), limit: 3) + ")"
        }
        if unconfirmed > 0 { line += ", \(unconfirmed) channel pushes not confirmed (typed instead)" }
        if queued > 0 { line += ", \(queued) still queued (" + live.queued.prefix(3).map { "@\($0.label) \($0.count)" }.joined(separator: ", ") + ")" }
        return line
    }

    private static func stewardLine(_ events: [LoggedEvent], live: Live) -> String? {
        let raised = events.filter { $0.kind == "escalation" }
        guard !raised.isEmpty || !live.escalations.isEmpty else { return nil }
        var line = "- steward: \(raised.count) escalation\(raised.count == 1 ? "" : "s")"
        if !raised.isEmpty { line += " (" + labelList(tally(raised.compactMap(\.session)).map(\.0), limit: 3) + ")" }
        if !live.escalations.isEmpty { line += "; open: " + live.escalations.prefix(2).map { SessionStore.clip($0, 90) }.joined(separator: "; ") }
        return line
    }

    /// "08:12" today, "Mon 08:12" this week, else the date.
    static func stamp(_ date: Date, now: Date) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if calendar.isDate(date, inSameDayAs: now) { formatter.dateFormat = "HH:mm" }
        else if now.timeIntervalSince(date) < 6 * 86_400 { formatter.dateFormat = "EEE HH:mm" }
        else { formatter.dateFormat = "MMM d HH:mm" }
        return formatter.string(from: date)
    }

    private static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

/// Crash loops and agents that never came up, for standup. An agent that exits soon after each
/// start or restart looks, one standup at a time, like any other exited agent; restarting it
/// again is the wrong move.
struct StartupHealth {
    /// An exit this soon after a start or restart counts towards a loop.
    static let quickExit: TimeInterval = 10 * 60
    /// More than `loopExits` quick exits within `loopWindow` is a crash loop.
    static let loopExits = 2
    static let loopWindow: TimeInterval = 60 * 60

    /// Per session: when each quick exit happened.
    private(set) var quickExits: [UUID: [Date]] = [:]
    /// Per session: the start (its `createdAt`) after which it reached its prompt.
    private(set) var readyAfter: [UUID: Date] = [:]

    mutating func sawReady(_ id: UUID, startedAt: Date) { readyAfter[id] = startedAt }

    mutating func sawExit(_ id: UUID, startedAt: Date, at now: Date) {
        guard now.timeIntervalSince(startedAt) < Self.quickExit else { return }
        quickExits[id, default: []].append(now)
        quickExits[id] = quickExits[id]?.filter { now.timeIntervalSince($0) < Self.loopWindow }
    }

    func reachedReady(_ id: UUID, startedAt: Date) -> Bool { readyAfter[id] == startedAt }

    func isCrashLooping(_ id: UUID, now: Date) -> Bool {
        (quickExits[id] ?? []).filter { now.timeIntervalSince($0) < Self.loopWindow }.count > Self.loopExits
    }

    func quickExitCount(_ id: UUID, now: Date) -> Int {
        (quickExits[id] ?? []).filter { now.timeIntervalSince($0) < Self.loopWindow }.count
    }

    mutating func forget(_ id: UUID) {
        quickExits[id] = nil
        readyAfter[id] = nil
    }
}
