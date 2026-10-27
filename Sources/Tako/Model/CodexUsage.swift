import Foundation

/// Codex has no statusLine; it writes usage into its session log instead. After each turn the
/// log's last `token_count` event carries the context use and the account's rate-limit windows.
enum CodexUsage {
    struct Reading: Equatable {
        var contextPercent: Double?
        var limits: RateLimits?
        /// Set when Codex says a limit was hit (e.g. "primary").
        var limitReached: Bool
    }

    /// The newest reading in a session log's text, scanning from the end.
    static func latest(in text: Substring) -> Reading? {
        for line in text.split(separator: "\n").reversed() where line.contains("\"token_count\"") {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let payload = json["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count" else { continue }
            return reading(from: payload)
        }
        return nil
    }

    static func reading(from payload: [String: Any]) -> Reading {
        var reading = Reading(limitReached: false)
        if let info = payload["info"] as? [String: Any],
           let window = info["model_context_window"] as? Double, window > 0,
           let used = (info["last_token_usage"] as? [String: Any])?["total_tokens"] as? Double {
            reading.contextPercent = min(100, used / window * 100)
        }
        if let limits = payload["rate_limits"] as? [String: Any] {
            var parsed = RateLimits()
            // Windows come as primary/secondary; which is which depends on the plan, so sort
            // them by length: up to a day is the short window, longer is the weekly one.
            for key in ["primary", "secondary"] {
                guard let entry = limits[key] as? [String: Any], let percent = entry["used_percent"] as? Double else { continue }
                let reset = (entry["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
                if (entry["window_minutes"] as? Double ?? 0) <= 1440 {
                    parsed.fiveHourPercent = percent
                    parsed.fiveHourResets = reset
                } else {
                    parsed.sevenDayPercent = percent
                    parsed.sevenDayResets = reset
                }
            }
            if parsed != RateLimits() { reading.limits = parsed }
            reading.limitReached = limits["rate_limit_reached_type"] is String
        }
        return reading
    }

    /// The session log for a thread, under the account's `sessions/YYYY/MM/DD/`. Recent days are
    /// checked first so a lookup doesn't walk months of history.
    static func logFile(thread: String, in root: URL, now: Date = Date()) -> URL? {
        let fm = FileManager.default
        let sessions = root.appendingPathComponent("sessions")
        let calendar = Calendar(identifier: .gregorian)
        for daysAgo in 0..<8 {
            guard let day = calendar.date(byAdding: .day, value: -daysAgo, to: now) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            let folder = sessions.appendingPathComponent(String(format: "%04d/%02d/%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0))
            if let match = (try? fm.contentsOfDirectory(atPath: folder.path))?.first(where: { $0.contains(thread) && $0.hasSuffix(".jsonl") }) {
                return folder.appendingPathComponent(match)
            }
        }
        guard let walker = fm.enumerator(at: sessions, includingPropertiesForKeys: nil) else { return nil }
        for case let file as URL in walker where file.lastPathComponent.contains(thread) && file.pathExtension == "jsonl" {
            return file
        }
        return nil
    }

    /// The most recently written session log under an account's root, from the last week.
    static func newestLog(in root: URL, now: Date = Date()) -> URL? {
        let fm = FileManager.default
        let calendar = Calendar(identifier: .gregorian)
        var newest: (url: URL, date: Date)?
        for daysAgo in 0..<7 {
            guard let day = calendar.date(byAdding: .day, value: -daysAgo, to: now) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            let folder = root.appendingPathComponent("sessions").appendingPathComponent(
                String(format: "%04d/%02d/%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0))
            let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files where file.pathExtension == "jsonl" {
                let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if date > (newest?.date ?? .distantPast) { newest = (file, date) }
            }
            if newest != nil { break }
        }
        return newest?.url
    }

    /// The last 256 KB of a log: token_count events are written at the end of every turn.
    static func tail(of file: URL, bytes: UInt64 = 256 * 1024) -> Substring? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        try? handle.seek(toOffset: end > bytes ? end - bytes : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        // Drop the partial first line when the read started mid-file.
        if end > bytes, let newline = text.firstIndex(of: "\n") { return text[text.index(after: newline)...] }
        return text[...]
    }
}
