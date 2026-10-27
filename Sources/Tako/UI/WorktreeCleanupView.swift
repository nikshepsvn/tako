import SwiftUI

/// Worktrees Tako or Claude created, with whether their work already landed, so leftovers
/// can be archived without guessing.
struct WorktreeEntry: Identifiable, Equatable {
    var id: String { path }
    let path: String
    let branch: String
    let repoRoot: String
    let merged: Bool
    let dirty: Bool
    let inUse: Bool
    /// What the janitor would do with it on its next pass, and why.
    var decision: WorktreeDecision?
}

/// What the store knows that the janitor's decision needs, captured on the main actor.
struct WorktreeContext: Sendable {
    /// Folder → when its agent was closed.
    var closed: [String: Date] = [:]
    /// Folder → the label of the open session working there.
    var users: [String: String] = [:]
    /// Folder → base branch, for agents the ledger doesn't know.
    var bases: [String: String] = [:]
}

enum WorktreeScanner {
    static func scan(repoRoots: [String], inUse: Set<String>, context: WorktreeContext = WorktreeContext(),
                     ledger: [WorktreeRecord] = [], now: Date = Date()) -> [WorktreeEntry] {
        var entries: [WorktreeEntry] = []
        let recorded = Dictionary(ledger.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        for root in Set(repoRoots) {
            guard let porcelain = runGit(["-C", root, "worktree", "list", "--porcelain"]) else { continue }
            let listed = Dictionary(WorktreeJanitor.parseWorktrees(porcelain).map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
            let head = runGit(["-C", root, "rev-parse", "--abbrev-ref", "HEAD"]) ?? "HEAD"
            let merged = Set((runGit(["-C", root, "branch", "--merged", head, "--format=%(refname:short)"]) ?? "").split(separator: "\n").map(String.init))
            for block in porcelain.components(separatedBy: "\n\n") {
                var path: String?
                var branch = "detached"
                for line in block.split(separator: "\n") {
                    if line.hasPrefix("worktree ") { path = String(line.dropFirst(9)) }
                    if line.hasPrefix("branch refs/heads/") { branch = String(line.dropFirst(18)) }
                }
                guard let path, path != root,
                      WorktreeJanitor.isAgentWorktree(path) else { continue }
                let dirty = !(runGit(["-C", path, "status", "--porcelain"]) ?? "").isEmpty
                // The janitor's own facts and plan, without acting on them.
                var facts = WorktreeJanitor.Facts(inUse: inUse.contains(path), dirty: dirty,
                                                  idleSince: context.closed[path] ?? recorded[path]?.created)
                facts.lock = WorktreeJanitor.lockState(reason: listed[path]?.lockReason, isRunning: WorktreeJanitor.isRunning)
                facts.detached = listed[path]?.detached ?? false
                if !facts.inUse { facts.risk = WorkAtRisk.evaluate(at: path, base: recorded[path]?.base ?? context.bases[path]) }
                entries.append(WorktreeEntry(path: path, branch: branch, repoRoot: root, merged: merged.contains(branch),
                                             dirty: dirty, inUse: inUse.contains(path),
                                             decision: WorktreeJanitor.decision(facts, usedBy: context.users[path], now: now)))
            }
        }
        return entries.sorted { $0.path < $1.path }
    }
}

struct WorktreeCleanupView: View {
    let repoRoots: [String]
    let inUse: Set<String>
    /// Worktree path → ids of the sessions that ran there, so archiving drops their checkpoints.
    var sessionIDs: [String: [String]] = [:]
    var context = WorktreeContext()
    /// Rows and janitor history given up front (snapshots); otherwise scanned on open.
    var preview: (entries: [WorktreeEntry], recent: [(date: Date, text: String)])? = nil
    let onDone: () -> Void
    @State private var entries: [WorktreeEntry] = []
    @State private var recent: [(date: Date, text: String)] = []
    @State private var loading = true
    @State private var message: String?
    /// Rows holding work that asked "Archive anyway?" once already.
    @State private var confirming: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Clean Up Worktrees").font(Typeface.title)
            Text("Archiving commits any leftover work to the worktree's branch, then removes the folder. Branches are kept. The janitor column says what Tako's own cleanup will do on its next pass.")
                .font(Typeface.callout).foregroundStyle(.secondary)
            if loading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            } else if entries.isEmpty {
                ContentUnavailableView("No Agent Worktrees", systemImage: "checkmark.seal").frame(minHeight: 140)
            } else {
                Table(entries) {
                    TableColumn("Worktree") { Text(shortPath($0.path)).help($0.path) }
                    TableColumn("Branch") { Text($0.branch).font(Typeface.code) }
                    TableColumn("Janitor") { entry in
                        let text = entry.decision?.text
                            ?? (entry.inUse ? "in use" : entry.merged ? "merged" : entry.dirty ? "uncommitted work" : "unmerged")
                        Text(text)
                            .foregroundStyle(Self.tint(entry))
                            .lineLimit(2)
                            .help(text)
                    }
                    .width(min: 220, ideal: 300)
                    TableColumn("") { entry in
                        let atRisk = !entry.merged || entry.dirty
                        let sure = confirming.contains(entry.id)
                        Button(atRisk && sure ? "Archive anyway" : "Archive") {
                            if atRisk && !sure { confirming.insert(entry.id) } else { archive(entry) }
                        }
                        .disabled(entry.inUse).controlSize(.small)
                        .help(atRisk ? "Its work is kept on the branch \(entry.branch)." : "Nothing in it is left to lose.")
                    }
                    .width(110)
                }
                .frame(minHeight: 200)
            }
            if !recent.isEmpty { recentActions }
            if let message { Text(message).font(Typeface.caption).foregroundStyle(.secondary) }
            HStack {
                Button("Archive All Clean") { entries.filter { $0.merged && !$0.dirty && !$0.inUse }.forEach(archive) }
                    .disabled(!entries.contains { $0.merged && !$0.dirty && !$0.inUse })
                Spacer()
                Button("Done", action: onDone).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 760)
        .task {
            if let preview {
                entries = preview.entries
                recent = preview.recent
                loading = false
            } else {
                await reload()
            }
        }
    }

    /// The janitor's last archives and cleared locks: worktrees it removed no longer have a row.
    private var recentActions: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Recently, by the janitor").font(Typeface.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(Array(recent.enumerated()), id: \.offset) { _, action in
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Text(elapsed(since: action.date) + " ago").font(Typeface.caption.monospacedDigit()).foregroundStyle(Tone.faint)
                        .frame(width: 56, alignment: .leading)
                    Text(action.text).font(Typeface.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .help(action.text)
                }
            }
        }
    }

    private static func tint(_ entry: WorktreeEntry) -> Color {
        guard let decision = entry.decision else { return entry.merged ? Palette.running : Palette.attention }
        switch decision.kind {
        case .archives: return Palette.running
        case .kept: return entry.inUse ? .secondary : Palette.attention
        case .blocked: return Palette.failed
        }
    }

    private func reload() async {
        loading = true
        let roots = repoRoots, used = inUse, context = context
        let scanned = await Task.detached { () -> ([WorktreeEntry], [(date: Date, text: String)]) in
            let entries = WorktreeScanner.scan(repoRoots: roots, inUse: used, context: context, ledger: WorktreeLedger.load())
            let recent = WorktreeJanitor.recentActions(since: Date().addingTimeInterval(-WorktreeJanitor.keepFor))
            return (entries, recent)
        }.value
        entries = scanned.0
        recent = scanned.1
        loading = false
    }

    private func archive(_ entry: WorktreeEntry) {
        Task {
            let sessions = sessionIDs[entry.path] ?? []
            let result = await Task.detached { () -> Result<String, ReviewError> in
                let outcome = Review.archive(worktree: entry.path, mainRoot: entry.repoRoot)
                if case .success = outcome {
                    for id in sessions { Checkpoints.prune(at: entry.repoRoot, session: id) }
                }
                return outcome
            }.value
            switch result {
            case .success(let text): message = "\(shortPath(entry.path)): \(text)"
            case .failure(let error): message = "⚠︎ \(error.description)"
            }
            await reload()
        }
    }
}
