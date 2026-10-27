import Foundation

/// An agent's closing message, kept whole enough for Sumi to act on. The finished event used
/// to carry only the reply's first line, cut at 140 characters: 43 of 80 arrived ending in
/// "…", and 47 were followed within a minute by read_terminal on the same agent.
enum FinalReply {
    /// One finished event's share of a digest: enough for a typical wrap-up, still bounded
    /// because the digest is typed into Sumi's terminal.
    static let limit = 1_500
    /// A digest with many finishes splits this between them, but never below `floor` each.
    static let digestBudget = 4_500
    static let floor = 300

    /// The reply on one line (a typed newline would submit Sumi's prompt early), with
    /// markdown noise and code blocks dropped. Past `limit` it keeps the opening and the end,
    /// where agents put their conclusion, and cuts at word boundaries.
    static func excerpt(_ text: String, limit: Int = limit) -> String? {
        let flat = flatten(text)
        guard !flat.isEmpty else { return nil }
        guard flat.count > limit else { return flat }
        let marker = " … "
        let room = max(limit - marker.count, 20)
        let headCount = room * 2 / 3
        let head = flat.prefix(headCount)
        let tail = flat.suffix(room - headCount)
        let headCut = head.lastIndex(of: " ").map { head[..<$0] } ?? head
        let tailCut = tail.firstIndex(of: " ").map { tail[tail.index(after: $0)...] } ?? tail
        return headCut.trimmingCharacters(in: .whitespaces) + marker + tailCut.trimmingCharacters(in: .whitespaces)
    }

    /// Each finished event's share when `count` of them share one digest.
    static func share(of count: Int) -> Int {
        count <= 3 ? limit : max(floor, digestBudget / count)
    }

    private static func flatten(_ text: String) -> String {
        var lines: [String] = []
        var inCode = false
        var codeLines = 0
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if inCode, codeLines > 0 { lines.append("[code]") }
                inCode.toggle()
                codeLines = 0
                continue
            }
            if inCode { codeLines += 1; continue }
            let plain = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "#> "))
            if !plain.isEmpty { lines.append(plain) }
        }
        return lines.joined(separator: " / ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
