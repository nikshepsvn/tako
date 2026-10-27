import SwiftUI

/// ⌃⌥Space from anywhere: type a task, press Return, and an agent starts on it in its own
/// worktree while you stay in whatever you were doing.
struct QuickAskView: View {
    @ObservedObject var store: SessionStore
    let dismiss: () -> Void
    @AppStorage("quickAskKind") private var kindName = SessionKind.claude.rawValue
    @AppStorage("quickAskFolder") private var savedFolder = ""
    @State private var text = ""
    @FocusState private var focused: Bool

    private var kind: SessionKind { SessionKind(rawValue: kindName).flatMap { $0.isAgent ? $0 : nil } ?? .claude }

    private var folders: [String] {
        let roots = store.sessions.reversed().map { $0.git.map(GitInfo.mainRoot) ?? $0.spec.cwd }
        return Array(NSOrderedSet(array: roots).array as? [String] ?? [])
    }

    private var folder: String {
        if !savedFolder.isEmpty, FileManager.default.fileExists(atPath: expandTilde(savedFolder)) { return savedFolder }
        return folders.first ?? NSHomeDirectory()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(spacing: Space.m) {
                WaveMark().frame(width: 22, height: 22)
                TextField("Ask a new agent…", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Typeface.title.weight(.regular))
                    .lineLimit(1...6)
                    .focused($focused)
                    .onSubmit(submit)
                    .acceptsAttachments($text)
            }
            HStack(spacing: Space.s) {
                SegmentedTabs(options: [(SessionKind.claude.rawValue, "Claude Code"), (SessionKind.codex.rawValue, "Codex")],
                              selection: $kindName)
                    .fixedSize()
                Menu {
                    // Recent folders only: an open panel would take focus and close Quick Ask.
                    if folders.isEmpty { Text("Start an agent in Tako first") }
                    ForEach(folders, id: \.self) { dir in Button(abbreviateHome(dir)) { savedFolder = dir } }
                } label: {
                    Label(URL(fileURLWithPath: expandTilde(folder)).lastPathComponent, systemImage: "folder")
                }
                .menuStyle(.borderlessButton)
                .tint(Tone.muted)
                .fixedSize()
                .help(abbreviateHome(folder))
                Spacer()
                HStack(spacing: Space.xs) { KeyboardHint(keys: "↵"); Text("Start") }
                HStack(spacing: Space.xs) { KeyboardHint(keys: "esc"); Text("Close") }
            }
            .font(Typeface.caption)
            .foregroundStyle(Tone.muted)
        }
        .padding(Space.l)
        .frame(width: 640)
        .foregroundStyle(Tone.text)
        .floatingSurface(fallback: Tone.deep)
        .onAppear { focused = true }
        .onKeyPress(.escape) { dismiss(); return .handled }
    }

    private func submit() {
        let task = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { return }
        // Settings ▸ "New agents start with" covers agents started from here too.
        store.dispatch(task, kinds: [kind], cwd: folder, options: AppSettings.defaultMode.map { AgentOptions(mode: $0) })
        text = ""
        dismiss()
    }
}
