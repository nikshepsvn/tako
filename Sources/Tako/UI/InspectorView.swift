import SwiftUI

enum InspectorTab: String, CaseIterable, Identifiable {
    case changes = "Changes", activity = "Activity", info = "Info", plan = "Plan"
    var id: String { rawValue }
}

/// Right-hand inspector for the selected session: review its changes, follow and steer its
/// turns, and see what it's running on.
struct InspectorView: View {
    @ObservedObject var store: SessionStore
    let actions: SessionActions

    var body: some View {
        Group {
            if let session = store.selected {
                InspectorContent(session: session, store: store, actions: actions)
                    .id(session.id)
            } else {
                EmptyMessage(symbol: "sidebar.right", title: "Nothing selected",
                             detail: "Select an agent to review its changes, follow its turns, and see what it's running on.")
            }
        }
        .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // The fill is the AppKit backing's (the theme's).
        .foregroundStyle(Tone.text)
        .tint(Palette.accent)
    }
}

private struct InspectorContent: View {
    @ObservedObject var session: TerminalSession
    @ObservedObject var store: SessionStore
    let actions: SessionActions

    private var tabs: [InspectorTab] {
        guard session.kind != .browser else { return [.info] }
        return session.pendingPlan != nil ? [.plan, .changes, .activity, .info] : [.changes, .activity, .info]
    }

    private var tab: InspectorTab { tabs.contains(store.inspectorTab) ? store.inspectorTab : tabs[0] }

    var body: some View {
        VStack(spacing: 0) {
            header
            if tabs.count > 1 {
                HStack {
                    SegmentedTabs(options: tabs.map { ($0, $0.rawValue) },
                                  selection: Binding(get: { tab }, set: { store.inspectorTab = $0 }),
                                  style: .underline)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Space.m)
            }
            Hairline()
            switch tab {
            case .plan: PlanView(session: session, store: store)
            case .changes: ChangesView(session: session, store: store)
            case .activity: ActivityView(session: session, store: store)
            case .info: InfoView(session: session, store: store, actions: actions)
            }
        }
        .onAppear { store.loadTurns(session) }
    }

    private var header: some View {
        HStack(spacing: Space.s) {
            AgentAvatar(kind: session.kind)
            VStack(alignment: .leading, spacing: 0) {
                Text(session.label).font(Typeface.headline).lineLimit(1)
                Text(session.kind == .browser ? (session.spec.url ?? "New tab") : shortPath(session.spec.workPath))
                    .font(Typeface.caption)
                    .foregroundStyle(Tone.faint)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: Space.xs)
            if session.kind != .browser { StateLabel(session: session) }
        }
        .padding(.horizontal, Space.m)
        .padding(.top, Space.m)
        .padding(.bottom, Space.s)
    }
}

// MARK: - Plan

private struct PlanView: View {
    @ObservedObject var session: TerminalSession
    let store: SessionStore

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                Text(planText)
                    .font(Typeface.body)
                    .lineSpacing(Space.xxs)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Space.l)
            }
            Hairline()
            HStack(spacing: Space.s) {
                Button("Keep Planning") {
                    _ = store.answer(session, .deny, reason: "Keep planning; the user wants to refine the plan before you start.")
                }
                .buttonStyle(PanelButtonStyle())
                Spacer()
                Button("Approve Plan") { _ = store.answer(session, .approve) }
                    .buttonStyle(PanelButtonStyle(prominent: true, tint: Palette.attention))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(Space.m)
        }
    }

    private var planText: AttributedString {
        let plan = session.pendingPlan ?? ""
        return (try? AttributedString(markdown: plan, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(plan)
    }
}

// MARK: - Changes

struct ReviewComment: Identifiable, Equatable {
    let id = UUID()
    let path: String
    let line: Int
    let code: String
    var text: String
    /// Set when made on an earlier turn's diff: `line` is where the code was as that turn ended.
    var turn: Int? = nil
}

/// Which changes the panel shows.
private enum ChangeScope: Hashable {
    case all, uncommitted, turn(Int)

    func title(turns: [Checkpoints.Turn]) -> String {
        switch self {
        case .all: return "All Changes"
        case .uncommitted: return "Uncommitted"
        case .turn(let index):
            return index == turns.last?.index ? "Last Turn" : "Turn \(index)"
        }
    }
}

private struct ChangesView: View {
    @ObservedObject var session: TerminalSession
    let store: SessionStore
    @AppStorage("diffSideBySide") private var sideBySide = false
    @AppStorage("diffIgnoreWhitespace") private var ignoreWhitespace = false
    @State private var scope: ChangeScope = .all
    @State private var files: [Review.FileDiff] = []
    /// Parsed once per load, off the main thread: the body re-runs on every session change.
    @State private var parsed: [String: [PatchLine]] = [:]
    @State private var selected: String?
    @State private var loading = false
    /// Kept on the session so drafts survive switching tabs or agents.
    private var comments: [ReviewComment] {
        get { session.reviewComments }
        nonmutating set { session.reviewComments = newValue }
    }
    @State private var draftLine: Int?
    @State private var draftText = ""
    @State private var result: String?
    @State private var working = false
    @State private var loadRequest = UUID()
    @State private var committing = false
    @State private var confirmRevert: Checkpoints.Turn?

    private var path: String { session.spec.workPath }
    /// Reverting while the agent writes would race it.
    private var agentBusy: Bool { session.state == .working || session.state == .starting || session.state.needsAttention }
    private var isWorktree: Bool { session.spec.worktreeBranch != nil || session.git?.isWorktree == true }
    private var totals: DiffStat {
        DiffStat(added: files.reduce(0) { $0 + $1.added }, removed: files.reduce(0) { $0 + $1.removed }, files: files.count)
    }

    private var selectedTurn: Checkpoints.Turn? {
        if case .turn(let index) = scope { return session.turns.first { $0.index == index } }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Hairline()
            if files.isEmpty {
                EmptyMessage(symbol: loading ? "hourglass" : "checkmark.circle",
                             title: loading ? "Reading changes…" : emptyTitle,
                             detail: loading ? "" : "Changes \(session.label) makes appear here. Double-click a line to leave a comment for it.")
            } else {
                fileList
                Hairline()
                patchView
            }
            Hairline()
            footer
        }
        .task(id: LoadKey(stat: session.diffStat, scope: scope, whitespace: ignoreWhitespace, turns: session.turns)) { await load() }
        .onAppear { session.readyForReview = false }
        .onReceive(store.$reviewTurn) { turn in
            guard let turn else { return }
            scope = .turn(turn)
            store.reviewTurn = nil
        }
        .sheet(isPresented: $committing) {
            CommitSheet(session: session, scope: scope == .uncommitted ? .uncommitted : .branch) { message in
                committing = false
                guard let message else { return }
                let directory = path
                run { Review.commit(at: directory, message: message).map { "Committed \($0)" } }
            }
        }
        .alert(item: $confirmRevert) { turn in
            Alert(title: Text("Revert files to before turn \(turn.index)?"),
                  message: Text("Files \(session.label) changed since then go back to how they were. Other agents' changes and the conversation aren't touched, and you can undo this."),
                  primaryButton: .destructive(Text("Revert Files")) { revert(to: turn.start, label: "before turn \(turn.index)", fromTurn: turn.index) },
                  secondaryButton: .cancel())
        }
    }

    private var emptyTitle: String {
        switch scope {
        case .all: return "No changes"
        case .uncommitted: return "Nothing uncommitted"
        case .turn: return "This turn changed no files"
        }
    }

    private struct LoadKey: Equatable {
        let stat: DiffStat?
        let scope: ChangeScope
        let whitespace: Bool
        /// Whole turns, not a count: a turn ending sets its end snapshot without adding one.
        let turns: [Checkpoints.Turn]
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: Space.s) {
            Menu {
                Picker("Changes", selection: $scope) {
                    Text("All Changes").tag(ChangeScope.all)
                    Text("Uncommitted").tag(ChangeScope.uncommitted)
                }
                .pickerStyle(.inline)
                if !session.turns.isEmpty {
                    Picker("Turns", selection: $scope) {
                        ForEach(session.turns.reversed()) { turn in
                            Text("\(turn.index). \(turn.prompt)").tag(ChangeScope.turn(turn.index))
                        }
                    }
                    .pickerStyle(.inline)
                }
            } label: {
                Text(scope.title(turns: session.turns)).font(Typeface.callout.weight(.medium))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Which changes to show")
            if !files.isEmpty {
                Text("\(files.count) file\(files.count == 1 ? "" : "s")").font(Typeface.caption).foregroundStyle(Tone.faint)
                DiffCount(added: totals.added, removed: totals.removed)
            }
            Spacer(minLength: Space.xs)
            if loading { ProgressView().controlSize(.mini) }
            Menu {
                Toggle("Side by Side", isOn: $sideBySide)
                Toggle("Hide Whitespace Changes", isOn: $ignoreWhitespace)
                Divider()
                Button("Refresh") { Task { await load() } }
            } label: {
                Image(systemName: "slider.horizontal.3").font(Typeface.caption.weight(.semibold)).foregroundStyle(Tone.muted)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("View options")
        }
        .padding(.horizontal, Space.m)
        .frame(height: Size.barHeight + Space.xs)
    }

    // MARK: Files

    private var fileList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(files) { file in
                    Button { selected = file.path; draftLine = nil } label: {
                        HStack(spacing: Space.s) {
                            Text(fileName(file.path))
                                .font(Typeface.callout)
                                .foregroundStyle(selected == file.path ? Tone.text : Tone.muted)
                            Text(fileFolder(file.path))
                                .font(Typeface.caption)
                                .foregroundStyle(Tone.faint)
                                .truncationMode(.head)
                            Spacer(minLength: Space.xs)
                            DiffCount(added: file.added, removed: file.removed)
                        }
                        .lineLimit(1)
                        .padding(.horizontal, Space.s)
                        .frame(height: 26)
                        .background(selected == file.path ? Tone.raised : .clear, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(file.path)
                    .contextMenu {
                        Button("Open in \(Editors.preferred?.name ?? "Editor")") {
                            Editors.open(((session.git?.root ?? path) as NSString).appendingPathComponent(file.path))
                        }
                        Button("Copy Path") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(file.path, forType: .string)
                        }
                    }
                    .accessibilityAddTraits(selected == file.path ? .isSelected : [])
                }
            }
            .padding(Space.xs)
        }
        .frame(height: min(CGFloat(files.count) * 26 + Space.s, 160))
    }

    private func fileName(_ path: String) -> String { (path as NSString).lastPathComponent }
    private func fileFolder(_ path: String) -> String {
        let folder = (path as NSString).deletingLastPathComponent
        return folder.isEmpty ? "" : folder
    }

    // MARK: Patch

    private var patchView: some View {
        let file = files.first { $0.path == selected } ?? files.first
        let fileComments = comments.filter { $0.path == file?.path }
        return VStack(spacing: 0) {
            DiffText(identity: (file?.path ?? "") + "\u{0}" + String(describing: scope),
                     lines: file.flatMap { parsed[$0.path] } ?? [], sideBySide: sideBySide,
                     commented: Set(fileComments.map(\.line))) { line in startComment(line) }
            if !fileComments.isEmpty || draftLine != nil {
                Hairline()
                VStack(alignment: .leading, spacing: Space.xs) {
                    ForEach(fileComments) { comment in
                        CommentBubble(line: comment.line, text: comment.text) { comments.removeAll { $0.id == comment.id } }
                    }
                    if let file, let number = draftLine, let line = parsed[file.path]?.first(where: { $0.newNumber == number && $0.kind != .removed }) {
                        draft(for: line, file: file)
                    }
                }
                .padding(.vertical, Space.xs)
                .background(Tone.deep)
            }
        }
    }

    @ViewBuilder private func draft(for line: PatchLine, file: Review.FileDiff) -> some View {
        HStack(spacing: Space.xs) {
            Text("Line \(line.newNumber ?? 0)").font(Typeface.caption.monospacedDigit()).foregroundStyle(Tone.faint)
            TextField("Comment for \(session.label)", text: $draftText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { addComment(file: file, line: line) }
            Button("Add") { addComment(file: file, line: line) }
                .disabled(draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel") { draftLine = nil }
        }
        .controlSize(.small)
        .padding(.horizontal, Space.s)
    }

    private func startComment(_ line: PatchLine) {
        guard line.kind != .header, let number = line.newNumber else { return }
        draftLine = number
        draftText = ""
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            if !comments.isEmpty {
                Button { sendComments() } label: {
                    Label("Send \(comments.count) Comment\(comments.count == 1 ? "" : "s") to \(session.label)", systemImage: "paperplane.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PanelButtonStyle(prominent: true))
            }
            HStack(spacing: Space.s) {
                if let turn = selectedTurn {
                    Button("Revert Files…") { confirmRevert = turn }
                        .buttonStyle(PanelButtonStyle())
                        .disabled(agentBusy)
                        .help(agentBusy ? "Wait for \(session.label) to finish its turn" : "Put the files \(session.label) changed back to how they were before this turn")
                } else {
                    Button("Commit…") { committing = true }
                        .buttonStyle(PanelButtonStyle())
                        .disabled(files.isEmpty)
                }
                Menu("More") {
                    Button("Push") { let directory = path; run { Review.push(at: directory) } }
                    Button("Open Pull Request…") { openPullRequest() }
                    if let base = session.spec.baseBranch, let branch = session.git?.branch, isWorktree {
                        Button("Merge into \(base)") {
                            let root = session.git.map(GitInfo.mainRoot) ?? path
                            run { Review.merge(branch: branch, into: base, mainRoot: root) }
                        }
                    }
                    Divider()
                    if let undo = undoPoint {
                        Button("Undo Last Revert") { revert(to: undo, label: "how they were before the last revert", fromTurn: nil) }
                    }
                    Button("Open in \(Editors.preferred?.name ?? "Editor")") { Editors.open(path) }
                    if isWorktree {
                        Divider()
                        Button("Archive Worktree") { store.onArchiveRequest?(session) }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer()
                if working { ProgressView().controlSize(.small) }
            }
            .disabled(working)
            if let result {
                Text(result)
                    .font(Typeface.caption)
                    .foregroundStyle(Tone.muted)
                    .textSelection(.enabled)
                    .lineLimit(3)
            }
        }
        .font(Typeface.callout)
        .padding(Space.m)
        .task(id: session.turns.count) { await refreshUndoPoint() }
    }

    @State private var undoPoint: String?

    private func refreshUndoPoint() async {
        let path = self.path, id = session.id.uuidString
        undoPoint = await Task.detached { Checkpoints.undoPoint(at: path, session: id) }.value
    }

    // MARK: Actions

    private func load() async {
        let request = UUID()
        loadRequest = request
        loading = true
        let path = self.path, base = session.spec.baseBranch, whitespace = ignoreWhitespace
        let reviewScope: Review.Scope
        switch scope {
        case .all: reviewScope = .branch
        case .uncommitted: reviewScope = .uncommitted
        case .turn(let index):
            guard let turn = session.turns.first(where: { $0.index == index }) else {
                loading = false
                scope = .all
                return
            }
            reviewScope = .turn(from: turn.start, to: turn.end)
        }
        let (loaded, lines) = await Task.detached {
            let diffs = Review.fileDiffs(at: path, base: base, scope: reviewScope, ignoreWhitespace: whitespace)
            return (diffs, Dictionary(diffs.map { ($0.path, PatchLine.parse($0.patch)) }, uniquingKeysWith: { first, _ in first }))
        }.value
        // A refresh triggered while Git was reading may finish first. Keep the latest load.
        guard loadRequest == request else { return }
        files = loaded
        parsed = lines
        if selected == nil || !loaded.contains(where: { $0.path == selected }) { selected = loaded.first?.path }
        loading = false
    }

    private func addComment(file: Review.FileDiff, line: PatchLine) {
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let number = line.newNumber else { return }
        // An earlier turn's diff numbers lines as that turn left them; later turns may have moved them.
        var pastTurn: Int?
        if case .turn(let index) = scope, index != session.turns.last?.index { pastTurn = index }
        comments.append(ReviewComment(path: file.path, line: number, code: line.text, text: text, turn: pastTurn))
        draftLine = nil
    }

    private func sendComments() {
        let body = comments.map { comment -> String in
            let place = comment.turn.map { "\(comment.path):\(comment.line) (line as of turn \($0); find it by the code)" }
                ?? "\(comment.path):\(comment.line)"
            return "\(place) — \(comment.text) (on: \(comment.code.trimmingCharacters(in: .whitespaces).prefix(80)))"
        }
        let message = "Review comments on your changes:\n" + body.map { "- " + $0 }.joined(separator: "\n") + "\nPlease address them."
        result = session.send(message, now: false) == "queued" ? "Queued for when \(session.label) finishes this turn" : "Sent to \(session.label)"
        session.record(.message, "Sent \(comments.count) review comments")
        comments = []
    }

    private func revert(to commit: String, label: String, fromTurn: Int?) {
        working = true
        store.restoreCheckpoint(session, to: commit, label: label, fromTurn: fromTurn) { outcome in
            working = false
            switch outcome {
            case .success: result = "Files restored to \(label). Undo it from More."
            case .failure(let error): result = "⚠︎ " + error.description
            }
            Task {
                await load()
                await refreshUndoPoint()
            }
        }
    }

    private func openPullRequest() {
        let directory = path, base = session.spec.baseBranch, context = session.agentStatus ?? session.summary
        working = true
        result = "Writing the pull request…"
        Task {
            let request = await Task.detached { () -> CommitWriter.PullRequest? in
                CommitWriter.pullRequest(diff: Review.patchText(at: directory, base: base, scope: .branch), context: context, at: directory)
            }.value
            working = false
            let title = request?.title ?? String((context ?? "Changes from \(session.label)").prefix(72))
            let alert = NSAlert()
            alert.messageText = "Open a pull request"
            alert.informativeText = "Pushes the branch and opens the pull request with gh."
            let field = NSTextField(string: title)
            field.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
            alert.accessoryView = field
            alert.addButton(withTitle: "Open Pull Request")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn else { result = nil; return }
            let finalTitle = field.stringValue, body = request?.body ?? "Opened from Tako."
            run { Review.openPullRequest(at: directory, base: base, title: finalTitle, body: body).map { "Opened \($0)" } }
        }
    }

    private func run(_ operation: @escaping @Sendable () -> Result<String, ReviewError>) {
        working = true
        result = nil
        Task {
            let outcome = await Task.detached { operation() }.value
            working = false
            switch outcome {
            case .success(let text):
                result = text
                session.record(.note, text)
            case .failure(let error):
                result = "⚠︎ " + error.description
            }
            await load()
            store.refreshReview(session)
        }
    }
}

/// Writes the message (with the agent's help), then commits.
private struct CommitSheet: View {
    let session: TerminalSession
    let scope: Review.Scope
    let finish: (String?) -> Void
    @State private var message = ""
    @State private var writing = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text("Commit Changes").font(Typeface.title)
            Text("Commits everything in \(shortPath(session.spec.workPath)).")
                .font(Typeface.callout)
                .foregroundStyle(Tone.muted)
            TextEditor(text: $message)
                .font(Typeface.code)
                .scrollContentBackground(.hidden)
                .padding(Space.s)
                .frame(minHeight: 120)
                .background(Tone.surface, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if message.isEmpty && !writing {
                        Text("Message").font(Typeface.code).foregroundStyle(Tone.faint).padding(Space.s + Space.xs)
                            .allowsHitTesting(false)
                    }
                }
            HStack(spacing: Space.s) {
                Button {
                    write()
                } label: {
                    if writing { ProgressView().controlSize(.small) } else { Label("Write It for Me", systemImage: "sparkles") }
                }
                .buttonStyle(PanelButtonStyle())
                .disabled(writing)
                .help("Draft the message from the diff with your Claude Code (or Codex) CLI")
                Spacer()
                Button("Cancel") { finish(nil) }
                    .buttonStyle(PanelButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Commit") { finish(message.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    .buttonStyle(PanelButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(Space.l)
        .frame(width: 480)
        .background(Tone.deep)
        .onAppear {
            if message.isEmpty { write() }
        }
    }

    private func write() {
        writing = true
        let path = session.spec.workPath, base = session.spec.baseBranch, scope = self.scope
        let context = session.agentStatus ?? session.summary
        Task {
            let text = await Task.detached {
                CommitWriter.commitMessage(diff: Review.patchText(at: path, base: base, scope: scope), context: context, at: path)
            }.value
            writing = false
            if let text { message = text } else if message.isEmpty {
                message = String((context ?? "Changes from \(session.label)").trimmingCharacters(in: CharacterSet(charactersIn: "› ")).prefix(72))
            }
        }
    }
}

private struct CommentBubble: View {
    let line: Int
    let text: String
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Circle().fill(Palette.accent).frame(width: 6, height: 6)
            Text("Line \(line)").font(Typeface.caption.monospacedDigit()).foregroundStyle(Tone.faint)
            Text(text).font(Typeface.callout).frame(maxWidth: .infinity, alignment: .leading)
            IconButton(symbol: "xmark", help: "Remove comment", action: onDelete)
        }
        .padding(.horizontal, Space.s)
    }
}

/// One rendered line of a unified diff, with its line numbers in the old and new file.
struct PatchLine: Identifiable, Equatable {
    enum Kind {
        case header, added, removed, context

        var tint: Color? {
            switch self {
            case .added: Palette.running
            case .removed: Palette.failed
            case .header, .context: nil
            }
        }
    }
    let id: Int
    let kind: Kind
    let text: String
    let newNumber: Int?
    var oldNumber: Int? = nil

    static func parse(_ patch: String) -> [PatchLine] {
        var result: [PatchLine] = []
        var newLine = 0, oldLine = 0
        // Lines still to come in the current hunk. Inside one, "---", "+++", "diff …" and the
        // like are the file's own lines (a removed YAML "---", an added "++i;"), not headers.
        var oldLeft = 0, newLeft = 0
        for (index, raw) in patch.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(raw)
            // The patch's trailing newline is not a line of the file, but inside a hunk an empty
            // line is a blank context line (git's diff.suppressBlankEmpty).
            if line.isEmpty && !(oldLeft > 0 && newLeft > 0) { continue }
            // Hunk lines start with "+", "-" or " ", so this can only be the next file's header.
            if line.hasPrefix("diff --git ") { oldLeft = 0; newLeft = 0 }
            let inHunk = oldLeft > 0 || newLeft > 0
            if line.hasPrefix("@@") {
                let lengths = Review.hunkLengths(raw)
                oldLeft = lengths?.old ?? 0
                newLeft = lengths?.new ?? 0
                // @@ -a,b +c,d @@
                let fields = line.split(separator: " ")
                if let plus = fields.first(where: { $0.hasPrefix("+") }),
                   let start = Int(plus.dropFirst().split(separator: ",").first ?? "") {
                    newLine = start
                }
                if let minus = fields.first(where: { $0.hasPrefix("-") }),
                   let start = Int(minus.dropFirst().split(separator: ",").first ?? "") {
                    oldLine = start
                }
                result.append(PatchLine(id: index, kind: .header, text: line, newNumber: nil))
            } else if line.hasPrefix("\\") || (!inHunk && (line.hasPrefix("diff ") || line.hasPrefix("index ")
                        || line.hasPrefix("--- ") || line.hasPrefix("+++ ") || line.hasPrefix("new file") || line.hasPrefix("deleted file"))) {
                continue
            } else if line.hasPrefix("+") {
                result.append(PatchLine(id: index, kind: .added, text: String(line.dropFirst()), newNumber: newLine))
                newLine += 1
                if inHunk { newLeft -= 1 }
            } else if line.hasPrefix("-") {
                result.append(PatchLine(id: index, kind: .removed, text: String(line.dropFirst()), newNumber: nil, oldNumber: oldLine))
                oldLine += 1
                if inHunk { oldLeft -= 1 }
            } else {
                result.append(PatchLine(id: index, kind: .context, text: String(line.dropFirst(min(1, line.count))),
                                        newNumber: newLine, oldNumber: oldLine))
                newLine += 1
                oldLine += 1
                if inHunk { oldLeft -= 1; newLeft -= 1 }
            }
        }
        return result
    }
}

/// A unified diff laid out in two columns: removals on the left, additions on the right, paired
/// up within each block of changes.
struct SplitRow: Identifiable {
    let id: Int
    var header: PatchLine?
    var left: PatchLine?
    var right: PatchLine?

    static func rows(from lines: [PatchLine]) -> [SplitRow] {
        var rows: [SplitRow] = []
        var removed: [PatchLine] = [], added: [PatchLine] = []
        func flush() {
            for index in 0..<max(removed.count, added.count) {
                let left = index < removed.count ? removed[index] : nil
                let right = index < added.count ? added[index] : nil
                rows.append(SplitRow(id: (left ?? right)?.id ?? rows.count, left: left, right: right))
            }
            removed = []
            added = []
        }
        for line in lines {
            switch line.kind {
            case .removed: removed.append(line)
            case .added: added.append(line)
            case .header:
                flush()
                rows.append(SplitRow(id: line.id, header: line))
            case .context:
                flush()
                rows.append(SplitRow(id: line.id, left: line, right: line))
            }
        }
        flush()
        return rows
    }
}

// MARK: - Activity

private struct ActivityView: View {
    @ObservedObject var session: TerminalSession
    let store: SessionStore

    var body: some View {
        VStack(spacing: 0) {
            if session.timeline.isEmpty && session.turns.isEmpty {
                EmptyMessage(symbol: "clock", title: "No activity yet",
                             detail: "Prompts, commands, approvals and test results appear here as \(session.label) works.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Space.l) {
                        let recent = session.timeline.filter { $0.date > session.lastViewedAt }
                        if !recent.isEmpty {
                            VStack(alignment: .leading, spacing: Space.xs) {
                                SectionHeader("Since you last looked")
                                Text(Recap.sentence(for: recent))
                                    .font(Typeface.body)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        if !session.turns.isEmpty { turns }
                        if !session.timeline.isEmpty { timeline }
                    }
                    .padding(Space.m)
                }
            }
            if session.kind.isAgent {
                Hairline()
                FollowUp(session: session)
            }
        }
    }

    private var turns: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            SectionHeader("Turns") { Text(String(session.turns.count)).monospacedDigit() }
            ForEach(session.turns.reversed()) { turn in
                TurnRow(turn: turn, session: session, store: store)
            }
        }
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            SectionHeader("Timeline") { Text(String(session.timeline.count)).monospacedDigit() }
            ForEach(session.timeline.reversed()) { event in
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Image(systemName: Recap.symbol(event.kind))
                        .font(Typeface.caption)
                        .foregroundStyle(Recap.color(event.kind))
                        .frame(width: Space.l)
                    Text(event.text)
                        .font(Typeface.callout)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .help(event.text)
                    Text(event.date.formatted(date: .omitted, time: .shortened))
                        .font(Typeface.caption.monospacedDigit())
                        .foregroundStyle(Tone.faint)
                }
            }
        }
    }
}

private struct TurnRow: View {
    let turn: Checkpoints.Turn
    let session: TerminalSession
    let store: SessionStore
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Space.s) {
            Text(String(turn.index))
                .font(Typeface.micro.monospacedDigit())
                .foregroundStyle(Tone.muted)
                .frame(width: 18, height: 18)
                .background(Tone.surface, in: Circle())
            VStack(alignment: .leading, spacing: 0) {
                Text(turn.prompt).font(Typeface.callout).lineLimit(1)
                Text(turn.end == nil ? "Running" : turn.date.formatted(date: .omitted, time: .shortened))
                    .font(Typeface.caption)
                    .foregroundStyle(turn.end == nil ? Palette.working : Tone.faint)
            }
            Spacer(minLength: Space.xs)
            if hovering {
                Button("Changes") {
                    store.reviewTurn = turn.index
                    store.inspectorTab = .changes
                }
                .buttonStyle(PanelButtonStyle())
                .controlSize(.small)
            }
        }
        .padding(Space.xs)
        .background(hovering ? Tone.surface : .clear, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        .onHover { hovering = $0 }
        .help(turn.prompt)
    }
}

/// Message the agent without switching to its terminal. While it's working, messages wait in a
/// queue and go out one per turn; "Send Now" steers the current turn instead.
private struct FollowUp: View {
    @ObservedObject var session: TerminalSession
    @State private var text = ""
    @State private var status: String?

    private var busy: Bool { session.state == .working || session.state == .starting }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            if !session.pendingMessages.isEmpty {
                SectionHeader("Queued") { Text(String(session.pendingMessages.count)) }
                ForEach(Array(session.pendingMessages.enumerated()), id: \.offset) { index, message in
                    HStack(spacing: Space.xs) {
                        Text(message).font(Typeface.callout).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        IconButton(symbol: "arrow.up.circle", help: "Send now") { session.sendQueuedNow(at: index) }
                        IconButton(symbol: "xmark", help: "Remove from queue") { session.removeQueued(at: index) }
                    }
                }
            }
            HStack(alignment: .bottom, spacing: Space.s) {
                TextField("Message \(session.label)…", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Typeface.body)
                    .lineLimit(1...5)
                    .onSubmit { send(now: false) }
                Menu {
                    Button(busy ? "Queue for After This Turn" : "Send") { send(now: false) }
                    Button("Send Now (Steer This Turn)") { send(now: true) }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(Typeface.caption.weight(.bold))
                        .foregroundStyle(text.isEmpty ? Tone.faint : Tone.floor)
                        .frame(width: Size.iconButton, height: Size.iconButton)
                        .background(text.isEmpty ? Tone.raised : Palette.accent, in: Circle())
                } primaryAction: {
                    send(now: false)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(text.isEmpty)
                .help(busy ? "Queue for after this turn (Return). More: send now." : "Send (Return)")
            }
            .padding(Space.s)
            .background(Tone.surface, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
            .acceptsAttachments($text)
            if let status { Text(status).font(Typeface.caption).foregroundStyle(Tone.faint) }
        }
        .padding(Space.m)
    }

    private func send(now: Bool) {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        let outcome = session.send(message, now: now)
        status = outcome == "queued" ? "Queued; goes out when this turn ends." : nil
        text = ""
    }
}

enum Recap {
    /// "6 edits, 2 commands, tests passed, finished: Added refresh rotation."
    static func sentence(for events: [TimelineEvent]) -> String {
        var parts: [String] = []
        let edits = events.filter { $0.kind == .edit }.count
        let tools = events.filter { $0.kind == .tool }.count
        if edits > 0 { parts.append("\(edits) edit\(edits == 1 ? "" : "s")") }
        if tools > 0 { parts.append("\(tools) command\(tools == 1 ? "" : "s")") }
        if let test = events.last(where: { $0.kind == .test }) { parts.append(test.text.lowercased().hasPrefix("tests passed") ? "tests passed" : "tests failing") }
        let approvals = events.filter { $0.kind == .approval }.count
        if approvals > 0 { parts.append("\(approvals) approval\(approvals == 1 ? "" : "s")") }
        if let failure = events.last(where: { $0.kind == .failure }) { parts.append("failed: \(failure.text)") }
        if let done = events.last(where: { $0.kind == .done }) { parts.append("finished: \(done.text)") }
        return parts.isEmpty ? "No activity." : parts.joined(separator: ", ").capitalizedFirst + "."
    }

    static func symbol(_ kind: TimelineEvent.Kind) -> String {
        switch kind {
        case .prompt: return "text.bubble"
        case .tool: return "terminal"
        case .edit: return "pencil"
        case .approval: return "hand.raised"
        case .test: return "checkmark.diamond"
        case .done: return "flag.checkered"
        case .failure: return "exclamationmark.triangle"
        case .message: return "paperplane"
        case .note: return "info.circle"
        }
    }

    static func color(_ kind: TimelineEvent.Kind) -> Color {
        switch kind {
        case .approval: return Palette.attention
        case .failure: return Palette.failed
        case .done, .test: return Palette.running
        case .prompt, .message: return Palette.working
        default: return Tone.faint
        }
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

// MARK: - Info

private struct InfoView: View {
    @ObservedObject var session: TerminalSession
    let store: SessionStore
    let actions: SessionActions
    @State private var copiedResume = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                section(session.kind == .browser ? "Browser" : "Session") {
                    row("Kind", session.kind.displayName)
                    row("Status", session.statusWord + (session.state.detail.map { " · " + $0 } ?? ""))
                    if session.kind == .browser {
                        row("Page", session.spec.url ?? "New tab", mono: true)
                        if let owner = session.spec.owner.flatMap({ id in store.sessions.first { $0.id == id } }) {
                            row("Agent", owner.label, mono: true)
                        }
                    } else {
                        row("Folder", abbreviateHome(session.spec.workPath), mono: true)
                    }
                    if let branch = session.git?.branch { row("Branch", branch, mono: true) }
                    if let base = session.spec.baseBranch { row("Base", base, mono: true) }
                    if let options = session.spec.options?.summary { row("Launched", options) }
                    if let port = session.spec.port, store.sessions.contains(where: { $0.kind == .server && $0.spec.port == port }) {
                        row("Dev server", "localhost:\(port)", mono: true)
                    }
                }
                let tasks = session.tasks
                if tasks.total > 0 {
                    section("Tasks", trailing: "\(tasks.done) of \(tasks.total)") {
                        Meter(fraction: Double(tasks.done) / Double(tasks.total))
                            .padding(.bottom, Space.xxs)
                        ForEach(tasks.order, id: \.self) { id in
                            let done = tasks.completed.contains(id)
                            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                                    .font(Typeface.caption)
                                    .foregroundStyle(done ? Palette.running : Tone.faint)
                                Text(tasks.subjects[id] ?? "Task")
                                    .foregroundStyle(done ? Tone.faint : Tone.text)
                                    .strikethrough(done, color: Tone.faint)
                            }
                        }
                    }
                }
                if session.kind.isAgent {
                    section("Usage") {
                        if let model = session.usage.model { row("Model", model) }
                        if let cost = session.usage.costUSD { row("Cost", String(format: "$%.2f", cost)) }
                        ResourceRow(steward: .shared, sessionID: session.id)
                        if let context = session.usage.contextPercent {
                            HStack(spacing: Space.s) {
                                Text("Context").foregroundStyle(Tone.muted).frame(width: 72, alignment: .leading)
                                Meter(fraction: context / 100, warning: 0.9)
                                Text("\(Int(context))%").monospacedDigit()
                                    .foregroundStyle(context >= 90 ? Palette.attention : Tone.muted)
                                    .frame(width: 34, alignment: .trailing)
                            }
                        }
                        if let limits = session.usage.limits { row("Limits", limitsText(limits)) }
                        if let evidence = session.testEvidence { row("Tests", evidence.summary) }
                        if session.usage == UsageSnapshot(), session.testEvidence == nil {
                            Text("Shows after the first turn.").foregroundStyle(Tone.faint)
                        }
                    }
                }
                section("Actions") {
                    VStack(spacing: 0) {
                        if session.kind != .browser {
                            ActionRow(symbol: "arrow.up.forward.app", title: "Open in \(Editors.preferred?.name ?? "Editor")", detail: "⌥⌘O") {
                                Editors.open(session.spec.workPath)
                            }
                        }
                        ActionRow(symbol: "folder", title: "Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.spec.workPath)])
                        }
                        if let id = session.spec.agentSessionId {
                            ActionRow(symbol: copiedResume ? "checkmark" : "doc.on.doc",
                                      title: copiedResume ? "Copied" : "Copy Resume Command",
                                      detail: String(id.prefix(8))) {
                                let command = session.kind.adapter?.resumeCommand(id) ?? id
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(command, forType: .string)
                                copiedResume = true
                            }
                            .help(id)
                            if session.kind == .claude {
                                ActionRow(symbol: "arrow.triangle.branch", title: "Fork Conversation") { _ = store.fork(session) }
                                    .help("Start a new agent from this point in the conversation")
                                ActionRow(symbol: "iphone", title: "Continue on Phone") { session.openRemoteControl() }
                                    .help("Continue with Claude Remote Control")
                            }
                        }
                    }
                    .padding(.horizontal, -Space.s)
                }
            }
            .padding(Space.m)
            .font(Typeface.callout)
        }
        .task(id: copiedResume) {
            guard copiedResume else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            copiedResume = false
        }
    }

    private func section<Content: View>(_ title: String, trailing: String? = nil, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            SectionHeader(title) { if let trailing { Text(trailing) } }
            content()
        }
    }

    private func limitsText(_ limits: RateLimits) -> String {
        [limits.fiveHourPercent.map { "5h \(Int($0))%" }, limits.sevenDayPercent.map { "week \(Int($0))%" }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func row(_ label: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Text(label).foregroundStyle(Tone.muted).frame(width: 72, alignment: .leading)
            Text(value)
                .font(mono ? Typeface.codeSmall : Typeface.callout)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(value)
            Spacer(minLength: 0)
        }
    }
}
