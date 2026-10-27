import Foundation

/// An append-only log file that rotates instead of truncating: past `maxBytes`, `name.log`
/// becomes `name.1.log` (and that `name.2.log`, up to `keep`), so the last stretch before a
/// problem is still there when someone looks. hooks.log used to truncate itself to zero at
/// 2 MB, which at full payloads was under an hour of history.
/// All I/O happens on one serial background queue with one long-lived handle.
final class RotatingLog: @unchecked Sendable {
    let url: URL
    let maxBytes: UInt64
    let keep: Int
    private let queue: DispatchQueue
    /// Touched on `queue` only.
    private var handle: FileHandle?

    init(url: URL, maxBytes: UInt64, keep: Int = 2) {
        self.url = url
        self.maxBytes = maxBytes
        self.keep = keep
        queue = DispatchQueue(label: "dev.hyperterm.log." + url.lastPathComponent, qos: .background)
    }

    /// `name.N.ext` for the Nth older file.
    func rotated(_ index: Int) -> URL {
        let base = url.deletingPathExtension().lastPathComponent
        return url.deletingLastPathComponent().appendingPathComponent("\(base).\(index).\(url.pathExtension)")
    }

    func append(_ line: String) {
        let data = Data((line.hasSuffix("\n") ? line : line + "\n").utf8)
        queue.async { self.write(data) }
    }

    /// Waits for everything appended so far to reach the file.
    func flush() { queue.sync {} }

    /// Runs on `queue` only.
    private func write(_ data: Data) {
        if handle == nil {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            handle = try? FileHandle(forWritingTo: url)
        }
        guard let current = handle, let end = try? current.seekToEnd() else { return }
        if end > 0, end + UInt64(data.count) > maxBytes {
            rotate()
            return write(data)
        }
        try? current.write(contentsOf: data)
    }

    private func rotate() {
        try? handle?.close()
        handle = nil
        let files = FileManager.default
        try? files.removeItem(at: rotated(keep))
        for index in stride(from: keep - 1, through: 1, by: -1) {
            try? files.moveItem(at: rotated(index), to: rotated(index + 1))
        }
        if keep > 0 { try? files.moveItem(at: url, to: rotated(1)) } else { try? files.removeItem(at: url) }
    }
}

/// One compact line per hook in ~/.hyperterm/hooks.log, for diagnosing status detection:
/// event, tool, session and sizes, never the payload. Prompts and tool output used to be
/// copied in full (up to 2,000 characters each), which filled the log in under an hour and
/// kept whatever the agents read on disk.
enum HookLog {
    nonisolated(unsafe) static var log: RotatingLog? = TestHost.isActive ? nil
        : RotatingLog(url: ControlPaths.supportDirectory.appendingPathComponent("hooks.log"), maxBytes: 2_000_000)
    nonisolated(unsafe) private static let formatter = ISO8601DateFormatter()
    private static let lock = NSLock()

    /// `json` is the parsed payload (empty when it didn't parse), `bytes` its size on the wire.
    static func append(source: String, sessionID: String?, json: [String: Any], bytes: Int) {
        guard let log else { return }
        log.append(line(date: Date(), source: source, sessionID: sessionID, json: json, bytes: bytes))
    }

    static func line(date: Date, source: String, sessionID: String?, json: [String: Any], bytes: Int) -> String {
        var parts = [stamp(date), source, sessionID ?? "-"]
        guard !json.isEmpty else { return (parts + ["unparsed", "bytes=\(bytes)"]).joined(separator: " ") }
        parts.append(json["hook_event_name"] as? String ?? json["type"] as? String ?? "?")
        if let tool = json["tool_name"] as? String { parts.append("tool=" + tool) }
        if let agent = json["session_id"] as? String { parts.append("agent=" + agent.prefix(8)) }
        parts.append("bytes=\(bytes)")
        for key in ["prompt", "last_assistant_message", "message"] {
            if let text = json[key] as? String { parts.append("\(key)=\(text.count)c") }
        }
        if let type = json["notification_type"] as? String { parts.append("kind=" + type) }
        return parts.joined(separator: " ")
    }

    static func stamp(_ date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return formatter.string(from: date)
    }
}

/// Lifecycle events worth keeping past the hook log's churn, one JSON object per line in
/// ~/.hyperterm/events.jsonl: sweeps of leftover processes, gc decisions, message deliveries
/// and their failures, approvals and how long they waited. Rare enough that 1 MB is weeks.
enum EventLog {
    nonisolated(unsafe) static var log: RotatingLog? = TestHost.isActive ? nil
        : RotatingLog(url: ControlPaths.supportDirectory.appendingPathComponent("events.jsonl"), maxBytes: 1_000_000)

    /// `kind` names the subsystem ("gc", "sweep", "message", "approval", "hook"); `fields`
    /// must be JSON values.
    static func record(_ kind: String, session: String? = nil, _ text: String, fields: [String: Any] = [:]) {
        guard let log, let line = line(date: Date(), kind: kind, session: session, text: text, fields: fields) else { return }
        log.append(line)
    }

    static func line(date: Date, kind: String, session: String?, text: String, fields: [String: Any]) -> String? {
        var object = fields
        object["t"] = HookLog.stamp(date)
        object["kind"] = kind
        object["text"] = text
        if let session { object["session"] = session }
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
