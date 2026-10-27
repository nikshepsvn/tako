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
}

enum WorktreeScanner {
    static func scan(repoRoots: [String], inUse: Set<String>) -> [WorktreeEntry] {
        var entries: [WorktreeEntry] = []
        for root in Set(repoRoots) {
            guard let porcelain = runGit(["-C", root, "worktree", "list", "--porcelain"]) else { continue }
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
                      path.contains("/.hyperterm/worktrees/") || path.contains("/.claude/worktrees/") else { continue }
                let dirty = !(runGit(["-C", path, "status", "--porcelain"]) ?? "").isEmpty
                entries.append(WorktreeEntry(path: path, branch: branch, repoRoot: root, merged: merged.contains(branch),
                                             dirty: dirty, inUse: inUse.contains(path)))
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
    let onDone: () -> Void
    @State private var entries: [WorktreeEntry] = []
    @State private var loading = true
    @State private var message: String?
    /// Rows holding work that asked "Archive anyway?" once already.
    @State private var confirming: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Clean Up Worktrees").font(Typeface.title)
            Text("Archiving commits any leftover work to the worktree's branch, then removes the folder. Branches are kept.")
                .font(Typeface.callout).foregroundStyle(.secondary)
            if loading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            } else if entries.isEmpty {
                ContentUnavailableView("No Agent Worktrees", systemImage: "checkmark.seal").frame(minHeight: 140)
            } else {
                Table(entries) {
                    TableColumn("Worktree") { Text(shortPath($0.path)).help($0.path) }
                    TableColumn("Branch") { Text($0.branch).font(Typeface.code) }
                    TableColumn("Status") { entry in
                        Text(entry.inUse ? "in use" : entry.merged ? "merged" : entry.dirty ? "uncommitted work" : "unmerged")
                            .foregroundStyle(entry.merged ? Palette.running : entry.inUse ? .secondary : Palette.attention)
                    }
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
            if let message { Text(message).font(Typeface.caption).foregroundStyle(.secondary) }
            HStack {
                Button("Archive All Clean") { entries.filter { $0.merged && !$0.dirty && !$0.inUse }.forEach(archive) }
                    .disabled(!entries.contains { $0.merged && !$0.dirty && !$0.inUse })
                Spacer()
                Button("Done", action: onDone).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640)
        .task { await reload() }
    }

    private func reload() async {
        loading = true
        let roots = repoRoots, used = inUse
        entries = await Task.detached { WorktreeScanner.scan(repoRoots: roots, inUse: used) }.value
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
