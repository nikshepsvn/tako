import Foundation

/// One line of events.jsonl, read back for the morning briefing (`standup since`) and `ht doctor`.
struct LoggedEvent {
    let date: Date
    let kind: String
    let session: String?
    let text: String
    let fields: [String: Any]

    func string(_ key: String) -> String? { fields[key] as? String }
    func int(_ key: String) -> Int? { (fields[key] as? NSNumber)?.intValue }
    func double(_ key: String) -> Double? { (fields[key] as? NSNumber)?.doubleValue }
}

extension EventLog {
    /// Reading back walks the rotated files only as far as `since` needs: at most `keep` + 1
    /// files of 1 MB, a few thousand lines, so it is safe on demand but never on the main thread.
    static func read(since: Date, from source: RotatingLog? = log) -> [LoggedEvent] {
        guard let source else { return [] }
        source.flush()
        let files = (stride(from: source.keep, through: 1, by: -1).map(source.rotated) + [source.url]).filter { url in
            // A rotated file last written before `since` holds nothing newer.
            guard url != source.url,
                  let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            else { return true }
            return modified >= since
        }
        let formatter = ISO8601DateFormatter()
        return files.flatMap { url -> [LoggedEvent] in
            guard let data = try? Data(contentsOf: url) else { return [] }
            return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
                guard let event = parse(line, formatter: formatter), event.date >= since else { return nil }
                return event
            }
        }
    }

    static func parse(_ line: Substring, formatter: ISO8601DateFormatter = ISO8601DateFormatter()) -> LoggedEvent? {
        guard var object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              let stamp = object.removeValue(forKey: "t") as? String, let date = formatter.date(from: stamp),
              let kind = object.removeValue(forKey: "kind") as? String else { return nil }
        let text = object.removeValue(forKey: "text") as? String ?? ""
        let session = object.removeValue(forKey: "session") as? String
        return LoggedEvent(date: date, kind: kind, session: session, text: text, fields: object)
    }
}

/// "@a, @b, @c +2" for a briefing line: names stay readable, the line stays bounded.
func labelList(_ labels: [String], limit: Int = 4) -> String {
    let named = labels.prefix(limit).map { $0.hasPrefix("@") ? $0 : "@" + $0 }.joined(separator: ", ")
    return labels.count > limit ? named + " +\(labels.count - limit)" : named
}

/// Counts in first-seen order, so a briefing lists the busiest names without reshuffling ties.
func tally(_ items: [String]) -> [(String, Int)] {
    var order: [String] = []
    var counts: [String: Int] = [:]
    for item in items {
        if counts[item] == nil { order.append(item) }
        counts[item, default: 0] += 1
    }
    return order.map { ($0, counts[$0] ?? 0) }.sorted { $0.1 > $1.1 }
}
