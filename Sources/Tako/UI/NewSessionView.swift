import SwiftUI

struct NewSessionDraft {
    var kind: SessionKind = .claude
    var label = ""
    var cwd = NSHomeDirectory()
    var command = ""
    var worktree = false
    /// nil: the account picked for new agents of this kind.
    var account: String?
    /// Agents: permission mode, model and effort.
    var options = AgentOptions(mode: AppSettings.defaultMode)
}

/// A sheet for starting anything: an agent, a shell, a server, a browser.
struct NewSessionView: View {
    @State var draft: NewSessionDraft
    let recentDirectories: [String]
    /// What an unnamed agent or shell will be called (alpha, bravo…).
    let defaultName: String
    let onCreate: (NewSessionDraft) -> Void
    let onCancel: () -> Void
    @FocusState private var focus: Field?

    private enum Field { case label, command }

    private var canCreate: Bool {
        !(draft.kind == .server && draft.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            Text("New Session").font(Typeface.title)

            HStack(spacing: Space.xs) {
                ForEach(SessionKind.allCases) { kind in
                    KindButton(kind: kind, selected: draft.kind == kind) {
                        draft.kind = kind
                        draft.account = nil
                        focus = kind == .server || kind == .browser ? .command : .label
                    }
                }
            }

            VStack(alignment: .leading, spacing: Space.m) {
                FieldRow(title: "Name") {
                    TextField("", text: $draft.label, prompt: Text(labelPlaceholder))
                        .textFieldStyle(.roundedBorder)
                        .font(Typeface.code)
                        .focused($focus, equals: .label)
                        .accessibilityLabel("Session name")
                }
                FieldRow(title: "Folder") {
                    Menu {
                        ForEach(recentDirectories, id: \.self) { dir in
                            Button(abbreviateHome(dir)) { draft.cwd = dir }
                        }
                        if !recentDirectories.isEmpty { Divider() }
                        Button("Choose Folder…") { chooseFolder() }
                    } label: {
                        Text(abbreviateHome(draft.cwd)).lineLimit(1).truncationMode(.head)
                    }
                    .help(draft.cwd)
                    .accessibilityLabel("Working folder")
                }
                if draft.kind.isAgent {
                    agentFields
                }
                FieldRow(title: commandTitle) {
                    TextField("", text: $draft.command, prompt: Text(commandPlaceholder))
                        .textFieldStyle(.roundedBorder)
                        .font(Typeface.code)
                        .focused($focus, equals: .command)
                        .accessibilityLabel(commandTitle)
                }
            }

            Text(hint)
                .font(Typeface.callout)
                .foregroundStyle(Tone.muted)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Space.s) {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(PanelButtonStyle())
                Button("Create") { onCreate(draft) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(PanelButtonStyle(prominent: true))
                    .disabled(!canCreate)
            }
        }
        .padding(Space.xl)
        .frame(width: 520)
        .foregroundStyle(Tone.text)
        .background(Tone.deep)
        .tint(Palette.accent)
        .onAppear { focus = draft.kind == .server || draft.kind == .browser ? .command : .label }
    }

    @ViewBuilder private var agentFields: some View {
        if AccountStore.shared.accounts(for: draft.kind).count > 1 {
            FieldRow(title: "Account") {
                Picker("", selection: Binding(
                    get: { draft.account ?? AccountStore.shared.preferredID(for: draft.kind) },
                    set: { draft.account = $0 })) {
                    ForEach(AccountStore.shared.accounts(for: draft.kind)) { account in
                        Text(account.name + (AccountStore.signedInEmail(account).map { " · \($0)" } ?? " · not signed in"))
                            .tag(account.id)
                    }
                }
                .labelsHidden()
                .accessibilityLabel("Account")
            }
        }
        FieldRow(title: "Permissions") {
            Picker("", selection: $draft.options.mode) {
                Text("As Configured").tag(PermissionMode?.none)
                Divider()
                ForEach(PermissionMode.allCases) { Text($0.title).tag(PermissionMode?.some($0)) }
            }
            .labelsHidden()
            .help(draft.options.mode?.detail ?? "Use the agent's own permission settings")
            .accessibilityLabel("Permissions")
        }
        FieldRow(title: "Model") {
            HStack(spacing: Space.s) {
                TextField("", text: Binding(get: { draft.options.model ?? "" },
                                            set: { draft.options.model = $0.isEmpty ? nil : $0 }),
                          prompt: Text("Default"))
                    .textFieldStyle(.roundedBorder)
                    .font(Typeface.code)
                    .accessibilityLabel("Model")
                if draft.kind == .claude {
                    Menu {
                        ForEach(AgentOptions.claudeModels, id: \.self) { model in
                            Button(model.capitalized) { draft.options.model = model }
                        }
                        Divider()
                        Button("Default") { draft.options.model = nil }
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                if draft.kind == .codex {
                    Picker("", selection: $draft.options.effort) {
                        Text("Default Effort").tag(ReasoningEffort?.none)
                        ForEach(ReasoningEffort.allCases) { Text("\($0.title) Effort").tag(ReasoningEffort?.some($0)) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel("Reasoning effort")
                }
            }
        }
        FieldRow(title: "") {
            Toggle("Work in its own worktree, on its own branch", isOn: $draft.worktree)
                .toggleStyle(.checkbox)
                .font(Typeface.callout)
        }
    }

    private var labelPlaceholder: String {
        let folder = URL(fileURLWithPath: expandTilde(draft.cwd)).lastPathComponent.lowercased()
        switch draft.kind {
        case .server: return "\(folder)-server"
        default: return defaultName
        }
    }

    private var commandTitle: String {
        switch draft.kind {
        case .claude, .codex: return "Arguments"
        case .server: return "Command"
        case .shell: return "Run"
        case .browser: return "Address"
        }
    }

    private var commandPlaceholder: String {
        switch draft.kind {
        case .claude, .codex, .shell: return "Optional"
        case .server: return "pnpm dev"
        case .browser: return "localhost:3000"
        }
    }

    private var hint: String {
        let label = draft.label.isEmpty ? labelPlaceholder : normalizeLabel(draft.label)
        switch draft.kind {
        case .claude: return "Runs Claude Code as \(label). Other agents can message it by that name."
        case .codex: return "Runs Codex as \(label). Agents reach it through Tako's tools."
        case .server: return "Runs the command as \(label). Its ports show in the sidebar; agents can read its logs and restart it."
        case .shell: return "A login shell named \(label)."
        case .browser: return "A Chromium browser named \(label) that agents can drive. It shares logins with your other Tako browsers."
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Working Folder"
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: expandTilde(draft.cwd))
        if panel.runModal() == .OK, let url = panel.url { draft.cwd = url.path }
    }
}

private struct KindButton: View {
    let kind: SessionKind
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: Space.xs) {
                KindMark(kind: kind, font: Typeface.headline)
                    .foregroundStyle(selected ? kind.tint : Tone.muted)
                    .frame(height: Space.l + Space.xs)
                Text(kind.displayName)
                    .font(Typeface.caption.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Tone.text : Tone.muted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Space.s)
            .background(selected ? Tone.raised : hovering ? Tone.surface : .clear,
                        in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(kind.displayName)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct FieldRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.m) {
            Text(title)
                .font(Typeface.callout)
                .foregroundStyle(Tone.muted)
                .frame(width: 84, alignment: .trailing)
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
