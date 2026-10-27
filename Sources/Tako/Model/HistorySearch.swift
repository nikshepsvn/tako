import Foundation

/// session_history's query: "find the session that was looking at the SSD". Sumi used to grep
/// ~/.claude/projects with Bash for this (45 times). Closed sessions are matched on what Tako
/// kept (label, folder, branch, summary, task, events), then on their transcripts; Claude
/// conversations Tako never ran come last, newest first. Every scan is bounded, so a query
/// costs a fraction of a second, not a crawl of the whole history. Blocking; run it off the
/// main thread.
enum HistorySearch {
    /// One closed session to search: what Tako kept, and where its transcript is.
    struct Candidate {
        let spec: LaunchSpec
        let kind: SessionKind
        let transcript: () -> URL?
    }

    struct Match {
        let spec: LaunchSpec
        /// "label", "summary", "transcript"…
        let field: String
        let snippet: String
    }

    struct LooseMatch: Equatable {
        let conversation: String
        let folder: String?
        let modified: Date
        let snippet: String
    }

    struct Limits {
        /// Bytes read from the end of each transcript.
        var perFile = 2 * 1024 * 1024
        /// Bytes read across every transcript of one query.
        var total = 96 * 1024 * 1024
        /// Conversations Tako never ran that are looked at, newest first.
        var looseFiles = 300
    }

    /// Lowercased words; a session matches when it holds every one.
    static func terms(_ query: String) -> [String] {
        query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { !$0.isEmpty }
    }

    static func search(_ candidates: [Candidate], query: String, limit: Int, limits: Limits = Limits(),
                       budget: inout Int) -> [Match] {
        let words = terms(query)
        guard !words.isEmpty else { return [] }
        var found: [Match] = []
        for candidate in candidates where found.count < limit {
            if let hit = metadataHit(candidate.spec, words) {
                found.append(Match(spec: candidate.spec, field: hit.field, snippet: hit.snippet))
                continue
            }
            guard budget > 0, let url = candidate.transcript(),
                  let text = read(url, bytes: min(limits.perFile, budget)) else { continue }
            budget -= text.utf8.count
            if let snippet = transcriptSnippet(text, words, kind: candidate.kind) {
                found.append(Match(spec: candidate.spec, field: "transcript", snippet: snippet))
            }
        }
        return found
    }

    /// The first of Tako's own fields that holds every word.
    static func metadataHit(_ spec: LaunchSpec, _ words: [String]) -> (field: String, snippet: String)? {
        let memory = spec.memory
        let fields: [(String, String?)] = [
            ("label", ([spec.label] + (spec.previousLabels ?? [])).joined(separator: " ")),
            ("folder", spec.cwd + (spec.worktreeBranch.map { " " + $0 } ?? "")),
            ("summary", spec.summary),
            ("task", memory?.task),
            ("ended", memory?.finalState),
            ("events", memory?.events?.joined(separator: " · ")),
        ]
        let everything = fields.compactMap(\.1).joined(separator: "\n").lowercased()
        guard words.allSatisfy(everything.contains) else { return nil }
        // Words can be spread over fields; name the field holding the first one.
        for (name, value) in fields {
            guard let value, value.lowercased().contains(words[0]) else { continue }
            return (name, snippet(value, around: words[0]))
        }
        return ("details", snippet(everything, around: words[0]))
    }

    /// A line of the rendered conversation holding the words, else the raw text around the first
    /// (a match inside a tool's output).
    static func transcriptSnippet(_ text: Substring, _ words: [String], kind: SessionKind) -> String? {
        let lower = text.lowercased()
        guard words.allSatisfy(lower.contains) else { return nil }
        let lines = kind.adapter?.renderTranscript(text) ?? []
        if let line = lines.last(where: { line in words.allSatisfy(line.lowercased().contains) })
            ?? lines.last(where: { $0.lowercased().contains(words[0]) }) {
            return snippet(line, around: words[0])
        }
        return snippet(String(text), around: words[0])
    }

    /// Claude conversations under `projects` that no closed session already covers, newest first.
    static func searchLoose(projects: URL, query: String, skip: Set<String>, limit: Int,
                            limits: Limits = Limits(), budget: inout Int) -> [LooseMatch] {
        let words = terms(query)
        guard !words.isEmpty, limit > 0 else { return [] }
        let fm = FileManager.default
        var files: [(url: URL, modified: Date)] = []
        for folder in (try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? [] {
            let entries = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for url in entries where url.pathExtension == "jsonl" && !skip.contains(url.deletingPathExtension().lastPathComponent) {
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                files.append((url, modified))
            }
        }
        files.sort { $0.modified > $1.modified }
        var found: [LooseMatch] = []
        for file in files.prefix(limits.looseFiles) where found.count < limit && budget > 0 {
            guard let text = read(file.url, bytes: min(limits.perFile, budget)) else { continue }
            budget -= text.utf8.count
            guard let snippet = transcriptSnippet(text, words, kind: .claude) else { continue }
            found.append(LooseMatch(conversation: file.url.deletingPathExtension().lastPathComponent,
                                    folder: workingFolder(of: file.url), modified: file.modified, snippet: snippet))
        }
        return found
    }

    /// The `cwd` its records carry: the folder name under projects/ loses which dashes were slashes.
    static func workingFolder(of transcript: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: transcript) else { return nil }
        defer { try? handle.close() }
        let head = String(decoding: (try? handle.read(upToCount: 64 * 1024)) ?? Data(), as: UTF8.self)
        for line in head.split(separator: "\n") {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let cwd = json["cwd"] as? String, !cwd.isEmpty else { continue }
            return cwd
        }
        return nil
    }

    /// About 160 characters around the first place `word` appears, on one line.
    static func snippet(_ text: String, around word: String, width: Int = 160) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        guard let range = flat.range(of: word, options: .caseInsensitive) else { return String(flat.prefix(width)) }
        let start = flat.index(range.lowerBound, offsetBy: -(width / 3), limitedBy: flat.startIndex) ?? flat.startIndex
        let end = flat.index(start, offsetBy: width, limitedBy: flat.endIndex) ?? flat.endIndex
        return (start > flat.startIndex ? "…" : "") + flat[start..<end] + (end < flat.endIndex ? "…" : "")
    }

    private static func read(_ url: URL, bytes: Int) -> Substring? {
        guard bytes > 0 else { return nil }
        return CodexUsage.tail(of: url, bytes: UInt64(bytes))
    }
}
