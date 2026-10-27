import Foundation

/// The pure parts of the worker agents' coordination tools: file-claim overlap, log cursors and
/// filters, and the change report. The store and the control handler hold the state and rules.

// MARK: - Claims

/// Paths as agents claim them: relative to the repository root, a file, a folder, or a glob.
enum ClaimPath {
    /// "./src/auth/" → "src/auth"; an absolute path inside `root` becomes relative to it. Nil
    /// for empty paths and ones that climb out (`..`), which name nothing in the project.
    static func normalize(_ raw: String, root: String?) -> String? {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Paths are quoted in messages typed into other agents' terminals: one line, no controls.
        guard !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        if let root, path.hasPrefix("/") {
            let base = root.hasSuffix("/") ? root : root + "/"
            if path == root { return nil }
            guard path.hasPrefix(base) else { return nil }
            path = String(path.dropFirst(base.count))
        }
        while path.hasPrefix("./") { path.removeFirst(2) }
        while path.hasSuffix("/") { path.removeLast() }
        guard !path.isEmpty, !path.hasPrefix("/"), path.count <= 300,
              !path.split(separator: "/").contains("..") else { return nil }
        return path
    }

    static func isGlob(_ path: String) -> Bool { path.contains { "*?[".contains($0) } }

    /// The folder a glob lives under: "src/**/*.ts" → "src". Empty for a top-level glob.
    static func base(_ path: String) -> String {
        guard isGlob(path) else { return path }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return parts.prefix { !isGlob(String($0)) }.joined(separator: "/")
    }

    /// `path` is `folder` or inside it.
    static func contains(_ folder: String, _ path: String) -> Bool {
        folder.isEmpty || path == folder || path.hasPrefix(folder + "/")
    }

    /// Two claims could name the same file. Ers on the side of overlap: two globs overlap when
    /// one's folder holds the other's, since proving them disjoint isn't worth the surprise.
    static func overlaps(_ a: String, _ b: String) -> Bool {
        switch (isGlob(a), isGlob(b)) {
        case (false, false): return contains(a, b) || contains(b, a)
        case (true, false): return matches(a, b) || contains(b, base(a))
        case (false, true): return matches(b, a) || contains(a, base(b))
        case (true, true): return contains(base(a), base(b)) || contains(base(b), base(a))
        }
    }

    /// Shell-style match where `*` also crosses folders, so "src/*.ts" covers "src/a/b.ts".
    static func matches(_ glob: String, _ path: String) -> Bool {
        fnmatch(glob, path, 0) == 0 || fnmatch(glob, path + "/x", 0) == 0
    }
}

/// One agent's hold on a path in a project.
struct FileClaim: Equatable {
    let owner: UUID
    var ownerLabel: String
    let path: String
    var expires: Date
}

/// A decision, API contract or heads-up an agent posted for the others in its project.
struct BoardNote: Codable, Equatable {
    let author: String
    let text: String
    let date: Date
}

/// One project's shared board: notes are append-only; claims are leases that end on release,
/// expiry, or their agent exiting.
struct TeamBoard {
    static let noteCap = 200
    static let claimCap = 40

    var notes: [BoardNote] = []
    var claims: [FileClaim] = []
    /// Notes are read from disk once, when the board is first used.
    var loaded = false

    mutating func dropExpired(now: Date = Date()) {
        claims.removeAll { $0.expires <= now }
    }

    /// Someone else's claims that overlap `path`.
    func conflicts(_ path: String, for owner: UUID) -> [FileClaim] {
        claims.filter { $0.owner != owner && ClaimPath.overlaps($0.path, path) }
    }

    /// Claims `paths` for `owner` where nobody else holds an overlapping path. Returns the paths
    /// claimed (or renewed) and, for the rest, who holds them.
    mutating func claim(_ paths: [String], owner: UUID, label: String, until expires: Date)
        -> (claimed: [String], refused: [(path: String, holders: [FileClaim])]) {
        var claimed: [String] = [], refused: [(String, [FileClaim])] = []
        for path in paths {
            let held = conflicts(path, for: owner)
            guard held.isEmpty else { refused.append((path, held)); continue }
            if let index = claims.firstIndex(where: { $0.owner == owner && $0.path == path }) {
                claims[index].expires = expires
            } else {
                guard claims.filter({ $0.owner == owner }).count < Self.claimCap else {
                    refused.append((path, []))
                    continue
                }
                claims.append(FileClaim(owner: owner, ownerLabel: label, path: path, expires: expires))
            }
            claimed.append(path)
        }
        return (claimed, refused)
    }

    /// Drops `owner`'s claims on `paths` (all of them when nil). Returns what was released.
    @discardableResult
    mutating func release(_ paths: [String]?, owner: UUID) -> [String] {
        let mine = claims.filter { $0.owner == owner && (paths?.contains($0.path) ?? true) }
        claims.removeAll { claim in mine.contains { $0.path == claim.path && $0.owner == claim.owner } }
        return mine.map(\.path)
    }

    mutating func add(_ note: BoardNote) {
        notes.append(note)
        if notes.count > Self.noteCap { notes.removeFirst(notes.count - Self.noteCap) }
    }

    /// A new agent's brief starts it where the others are: the latest notes and live claims, in
    /// at most `limit` characters. Nil for an empty board, so a brief without one is unchanged.
    func briefSection(project: String, now: Date = Date(), limit: Int = 600) -> String? {
        let live = claims.filter { $0.expires > now }
        guard !notes.isEmpty || !live.isEmpty else { return nil }
        let head = "Team board for \(project) (team_board read for all of it):"
        var claimLine: String?
        if !live.isEmpty {
            let byOwner = Dictionary(grouping: live, by: \.ownerLabel)
            claimLine = "Claimed: " + byOwner.keys.sorted().map { "@\($0) " + byOwner[$0]!.map(\.path).joined(separator: ", ") }
                .joined(separator: "; ")
            claimLine = Self.clip(claimLine!, 200)
        }
        var noteLines = notes.suffix(5).map { "- @\($0.author): " + Self.clip($0.text.split(whereSeparator: \.isNewline).joined(separator: " "), 110) }
        func text() -> String { ([head] + noteLines + (claimLine.map { [$0] } ?? [])).joined(separator: "\n") }
        // The oldest notes give way first; claims say who to talk to before editing.
        while text().count > limit, !noteLines.isEmpty { noteLines.removeFirst() }
        return Self.clip(text(), limit)
    }

    private static func clip(_ text: String, _ limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }
}

// MARK: - Logs

/// Reading a terminal's output a slice at a time. Scrollback has no stable line numbers, so a
/// cursor names the last few lines read instead: the next read returns what follows them.
enum LogTail {
    /// Lines from a screen read, without the blank rows below the last output.
    static func lines(_ text: String) -> [String] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        return lines
    }

    /// How many non-empty lines a cursor covers: enough that a repeated log line rarely fools it.
    static let anchorLength = 3

    /// The cursor after `lines`: a hash of its last few non-empty lines ("0" for no output).
    static func cursor(_ lines: [String]) -> String {
        anchor(lines, endingAt: lines.count - 1).map(hash) ?? "0"
    }

    /// Lines after the cursor's position, or nil when it isn't in `lines` (scrolled away or cleared).
    static func after(_ cursor: String, in lines: [String]) -> [String]? {
        if cursor == "0" { return lines }
        for end in stride(from: lines.count - 1, through: 0, by: -1) {
            guard let anchor = anchor(lines, endingAt: end), hash(anchor) == cursor else { continue }
            return Array(lines[(end + 1)...])
        }
        return nil
    }

    /// The last `anchorLength` non-empty lines up to `end`, when `end` itself is non-empty.
    private static func anchor(_ lines: [String], endingAt end: Int) -> [String]? {
        guard lines.indices.contains(end), !lines[end].trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        var picked: [String] = []
        var index = end
        while index >= 0, picked.count < anchorLength {
            if !lines[index].trimmingCharacters(in: .whitespaces).isEmpty { picked.append(lines[index]) }
            index -= 1
        }
        return picked
    }

    /// FNV-1a: stable across runs, unlike `hashValue`, so a cursor survives an app restart.
    private static func hash(_ lines: [String]) -> String {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in lines.joined(separator: "\n").utf8 {
            value ^= UInt64(byte)
            value = value &* 0x100_0000_01b3
        }
        return String(value, radix: 16)
    }

    static let errorPattern = try! NSRegularExpression(
        pattern: #"\w*(error|exception)s?\b|\berr!|\b(fatal|panic|panicked|traceback|failed|failure|uncaught|unhandled|segmentation fault)\b|✗|✘"#,
        options: [.caseInsensitive])

    /// "0 errors", "no failures": summaries that say all is well.
    static let allClearPattern = try! NSRegularExpression(
        pattern: #"\b(0|no) (errors?|failures?|failed)\b"#, options: [.caseInsensitive])

    /// Error lines, each with the indented lines under it (a stack trace) up to `context`.
    static func errors(_ lines: [String], context: Int = 8) -> [String] {
        var kept: [String] = []
        var trailing = 0
        for line in lines {
            if matches(errorPattern, line), !matches(allClearPattern, line) {
                kept.append(line)
                trailing = context
            } else if trailing > 0, line.first == " " || line.first == "\t" {
                kept.append(line)
                trailing -= 1
            } else {
                trailing = 0
            }
        }
        return kept
    }

    static func matches(_ regex: NSRegularExpression, _ line: String) -> Bool {
        regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    /// A pattern as agents write it: a regular expression, or failing that the literal text.
    static func regex(_ pattern: String) -> NSRegularExpression? {
        guard !pattern.isEmpty else { return nil }
        return (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]))
            ?? (try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: pattern), options: [.caseInsensitive]))
    }
}

// MARK: - Changes

/// Another agent's work as text an agent can act on: where it lives, its commits, its files,
/// and optionally the patch. Blocks on Git; run it off the main thread.
enum AgentChanges {
    static let patchLimit = 60_000

    static func report(at path: String, base: String?, uncommitted: Bool, patch: Bool, paths: [String]) -> String {
        guard FileManager.default.fileExists(atPath: path), let head = runGit(["-C", path, "rev-parse", "--short", "HEAD"]) else {
            return "\(abbreviateHome(path)) isn't a Git repository with commits, so there are no changes to show."
        }
        let branch = Review.currentBranch(at: path) ?? "HEAD"
        var lines = ["Workspace \(abbreviateHome(path)) · branch \(branch) at \(head)" + (base.map { " · base \($0)" } ?? "")]
        if !uncommitted, let base, let commits = commitList(at: path, base: base), !commits.isEmpty {
            lines.append("Commits since \(base):")
            lines += commits.map { "  " + $0 }
        }
        var files = Review.fileDiffs(at: path, base: base, scope: uncommitted ? .uncommitted : .branch)
        if !paths.isEmpty {
            files = files.filter { file in paths.contains { ClaimPath.overlaps($0, file.path) } }
        }
        let what = uncommitted ? "Uncommitted changes" : (base == nil ? "Uncommitted changes (no base branch)" : "Changes since \(base!), uncommitted included")
        guard !files.isEmpty else {
            lines.append("\(what): none" + (paths.isEmpty ? "." : " in \(paths.joined(separator: ", "))."))
            return lines.joined(separator: "\n")
        }
        let added = files.reduce(0) { $0 + $1.added }, removed = files.reduce(0) { $0 + $1.removed }
        lines.append("\(what): \(files.count) file\(files.count == 1 ? "" : "s"), +\(added) −\(removed)")
        lines += files.map { "  \($0.path) +\($0.added) −\($0.removed)" }
        guard patch else { return lines.joined(separator: "\n") }
        var text = files.map(\.patch).joined(separator: "\n")
        if text.count > patchLimit {
            text = String(text.prefix(patchLimit)) + "\n… patch cut at \(patchLimit / 1000)k characters; pass paths to see the rest"
        }
        return lines.joined(separator: "\n") + "\n\n" + text
    }

    /// Commits on the branch that its base doesn't have, newest first (at most 30).
    private static func commitList(at path: String, base: String) -> [String]? {
        guard base != "HEAD", let mergeBase = runGit(["-C", path, "merge-base", "HEAD", base]) else { return nil }
        let log = runGit(["-C", path, "log", "--oneline", "--no-decorate", "-n", "30", "\(mergeBase)..HEAD"]) ?? ""
        return log.split(separator: "\n").map(String.init)
    }
}
