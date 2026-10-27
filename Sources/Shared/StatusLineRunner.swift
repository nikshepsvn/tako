import Foundation

/// The work behind `ht statusline`, which Claude runs on every statusline refresh (a few times a
/// second per busy agent; ~43,000 `ht` processes in two days). The `ht` process itself is
/// unavoidable, so everything it starts is trimmed instead:
/// - Tako only hears about a refresh when a field it reads changed (or after a long quiet spell).
/// - The user's own statusline output is reused for identical input within a short TTL, so a
///   python statusline isn't started again for a refresh that would print the same thing.
/// - A plain command (`python3 /path/script.py statusline`) is started directly, not via `sh -c`.
enum StatusLineRunner {
    /// How long the user's statusline output is reused for identical input.
    static let outputTTL: TimeInterval = 2
    /// Unchanged telemetry is still re-sent this often, so a restarted Tako catches up.
    static let reportHeartbeat: TimeInterval = 30

    // MARK: - Reporting to Tako

    /// The statusline fields Tako reads (cost, context, model, rate limits), canonicalized. Two
    /// refreshes with the same digest tell Tako nothing new.
    static func reportDigest(_ input: Data) -> String {
        guard let json = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] else { return "" }
        let relevant: [String: Any] = [
            "cost": (json["cost"] as? [String: Any])?["total_cost_usd"] ?? NSNull(),
            "context": (json["context_window"] as? [String: Any])?["used_percentage"] ?? NSNull(),
            "model": (json["model"] as? [String: Any])?["display_name"] ?? NSNull(),
            "limits": json["rate_limits"] ?? NSNull(),
        ]
        return canonicalHash(relevant)
    }

    /// Whether this refresh should be sent to Tako, recording it when so. The last report's digest
    /// is a small file per session; its mtime is when it was sent.
    static func reportDue(session: String, input: Data, directory: URL = cacheDirectory, now: Date = Date()) -> Bool {
        let file = directory.appendingPathComponent(safeName(session) + ".report")
        let digest = reportDigest(input)
        if let last = try? String(contentsOf: file, encoding: .utf8), last == digest,
           let sent = modificationDate(file), now.timeIntervalSince(sent) < reportHeartbeat {
            return false
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data(digest.utf8).write(to: file, options: .atomic)
        return true
    }

    // MARK: - The user's own statusline

    /// The user's statusLine command, from the settings of the account this agent runs under:
    /// `$CLAUDE_CONFIG_DIR/settings.json`, else `~/.claude/settings.json`. Tako's own command is
    /// ignored so a settings file that points back at `ht statusline` can't recurse.
    static func userCommand(environment: [String: String], home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        let root = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? home.appendingPathComponent(".claude")
        guard let data = try? Data(contentsOf: root.appendingPathComponent("settings.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let statusLine = json["statusLine"] as? [String: Any],
              let command = statusLine["command"] as? String,
              !command.trimmingCharacters(in: .whitespaces).isEmpty,
              !command.contains("ht statusline") else { return nil }
        return command
    }

    /// Characters a shell passes through unchanged, so a command made only of these (and spaces)
    /// means the same split on whitespace as it does to `sh`.
    private static let plainCharacters = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-./:@%+,= ")

    /// The command as an argv when no shell is needed to run it, else nil.
    static func plainArgv(_ command: String) -> [String]? {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.unicodeScalars.allSatisfy(plainCharacters.contains) else { return nil }
        let argv = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        // `FOO=1 cmd` is an environment assignment to the shell.
        guard let program = argv.first, !program.contains("=") else { return nil }
        return argv
    }

    /// The executable `sh` would run for `name`: a path as given, else the first match on PATH.
    static func resolveExecutable(_ name: String, path: String?, cwd: String = FileManager.default.currentDirectoryPath) -> String? {
        let fm = FileManager.default
        if name.contains("/") {
            let full = name.hasPrefix("/") ? name : (cwd as NSString).appendingPathComponent(name)
            return fm.isExecutableFile(atPath: full) ? full : nil
        }
        for dir in (path ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":") where !dir.isEmpty {
            let candidate = (String(dir) as NSString).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: candidate, isDirectory: &isDirectory), !isDirectory.boolValue,
               fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// The executable and arguments to start: direct for a plain command, else `/bin/sh -c`.
    static func launchPlan(command: String, environment: [String: String]) -> (executable: String, arguments: [String]) {
        if let argv = plainArgv(command), let executable = resolveExecutable(argv[0], path: environment["PATH"]) {
            return (executable, Array(argv.dropFirst()))
        }
        return ("/bin/sh", ["-c", command])
    }

    /// The input with the fields that change on every refresh (elapsed times) removed, so two
    /// refreshes that would print the same line share a key. Includes the command, so a settings
    /// change takes effect at once.
    static func outputKey(command: String, input: Data) -> String {
        guard var json = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] else {
            return canonicalHash(["command": command, "raw": String(decoding: input, as: UTF8.self)])
        }
        if var cost = json["cost"] as? [String: Any] {
            cost.removeValue(forKey: "total_duration_ms")
            cost.removeValue(forKey: "total_api_duration_ms")
            json["cost"] = cost
        }
        return canonicalHash(["command": command, "input": json])
    }

    /// The user's statusline for this input: reused from the last run when the key matches and
    /// it is fresh, else run now and remembered.
    static func render(input: Data, environment: [String: String], directory: URL = cacheDirectory,
                       now: Date = Date(), run: (String, [String], Data) -> Data = runCommand) -> Data {
        guard let command = userCommand(environment: environment) else { return Data() }
        let session = environment["HT_SESSION_ID"] ?? sessionID(input) ?? "default"
        let key = outputKey(command: command, input: input)
        let file = directory.appendingPathComponent(safeName(session) + ".out")
        if let cached = cachedOutput(file: file, key: key, now: now) { return cached }
        let plan = launchPlan(command: command, environment: environment)
        let output = run(plan.executable, plan.arguments, input)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? (Data((key + "\n").utf8) + output).write(to: file, options: .atomic)
        return output
    }

    static func cachedOutput(file: URL, key: String, now: Date) -> Data? {
        guard let written = modificationDate(file), now.timeIntervalSince(written) < outputTTL, now >= written,
              let data = try? Data(contentsOf: file),
              let newline = data.firstIndex(of: 0x0A),
              String(decoding: data[data.startIndex..<newline], as: UTF8.self) == key else { return nil }
        return Data(data[(newline + 1)...])
    }

    /// Starts the command with `input` on stdin and returns its stdout.
    static func runCommand(executable: String, arguments: [String], input: Data) -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return Data() }
        stdin.fileHandleForWriting.write(input)
        try? stdin.fileHandleForWriting.close()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return output
    }

    // MARK: - Helpers

    /// Per-user temp dir: the state is only worth keeping for seconds.
    static var cacheDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ht-statusline")
    }

    private static func sessionID(_ input: Data) -> String? {
        ((try? JSONSerialization.jsonObject(with: input)) as? [String: Any])?["session_id"] as? String
    }

    private static func safeName(_ session: String) -> String {
        let name = session.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return name.isEmpty ? "default" : String(name.prefix(80))
    }

    private static func modificationDate(_ file: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
    }

    /// FNV-1a over sorted-key JSON: stable across runs, and cheap enough for a process that
    /// lives for milliseconds.
    private static func canonicalHash(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed])) ?? Data()
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}
