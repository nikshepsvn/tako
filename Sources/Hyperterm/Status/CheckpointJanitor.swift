import Foundation

/// Deletes checkpoint refs (`refs/kuronami/<session>/…`) of sessions that are gone for good.
/// Closing keeps them, since a closed agent can be reopened and its turns reviewed; they used
/// to go only when an agent fell off the closed list, so crashed, swept and older sessions'
/// refs piled up in every repository.
enum CheckpointJanitor {
    /// A session Tako doesn't know (another Tako with its own HT_HOME, a dev build) keeps its
    /// refs until its newest checkpoint is this old.
    static let keepFor: TimeInterval = 7 * 24 * 3600

    /// `for-each-ref --format=%(refname)%09%(committerdate:unix)` → each session's newest checkpoint.
    static func sessions(inListing listing: String) -> [String: Date] {
        var newest: [String: Date] = [:]
        let prefix = Checkpoints.namespace + "/"
        for line in listing.split(separator: "\n") {
            let fields = line.split(separator: "\t")
            guard fields.count == 2, fields[0].hasPrefix(prefix) else { continue }
            let parts = fields[0].dropFirst(prefix.count).split(separator: "/")
            guard parts.count >= 2, let seconds = Double(fields[1]) else { continue }
            let date = Date(timeIntervalSince1970: seconds)
            newest[String(parts[0])] = max(newest[String(parts[0])] ?? date, date)
        }
        return newest
    }

    /// Sessions whose refs can go: not kept, and quiet for `keepFor`.
    static func stale(_ found: [String: Date], keep: Set<String>, now: Date = Date(), keepFor: TimeInterval = keepFor) -> [String] {
        found.filter { !keep.contains($0.key) && now.timeIntervalSince($0.value) >= keepFor }.keys.sorted()
    }

    /// Prunes stale sessions' checkpoints in each repository and notes them in hooks.log.
    /// Blocks; run it off the main thread.
    static func collect(roots: Set<String>, keep: Set<String>, now: Date = Date(),
                        log: (String, String?) -> Void = { HookLog.append(source: "gc", sessionID: $1, payload: $0) }) {
        for root in roots.sorted() {
            let format = "--format=%(refname)%09%(committerdate:unix)"
            guard let listing = Git.run(["for-each-ref", format, Checkpoints.namespace + "/"], at: root) else { continue }
            let stale = stale(sessions(inListing: listing), keep: keep, now: now)
            for session in stale { Checkpoints.prune(at: root, session: session) }
            if !stale.isEmpty {
                log("pruned checkpoints of \(stale.count) closed session\(stale.count == 1 ? "" : "s") in \(abbreviateHome(root))", nil)
            }
        }
    }
}
