import AppKit
import SwiftUI

struct SwitcherItem: Identifiable {
    enum Kind { case session(TerminalSession), message(TerminalSession, String), action(() -> Void) }
    let id: String
    let title: String
    let subtitle: String?
    let symbol: String
    let tint: Color
    let kind: Kind
    var group = "Actions"
    /// Drawn as this kind's mark (an agent's logo) instead of `symbol`.
    var mark: SessionKind?
}

/// ⌘P: jump to a terminal, run an action, or "@label message" to message a terminal.
@MainActor
enum SwitcherModel {
    static func items(query raw: String, store: SessionStore, quickCreate: @escaping (SessionKind) -> Void) -> [SwitcherItem] {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let message = messageItem(query, store: store) { return [message] }
        let commandOnly = query.hasPrefix(">")
        let search = commandOnly ? String(query.dropFirst()).trimmingCharacters(in: .whitespaces) : query
        let candidates: [TerminalSession] = commandOnly ? [] : store.sessions
        let ranked: [(session: TerminalSession, score: Int, index: Int)] = candidates.enumerated()
            .map { index, session in (session: session, score: score(search, session), index: index) }
            .filter { $0.score > 0 }
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.index < $1.index
            }
        let sessions: [SwitcherItem] = ranked.map { result in
            let session = result.session
            return SwitcherItem(id: session.id.uuidString, title: session.label,
                                subtitle: [session.statusWord, session.summary ?? shortPath(session.spec.cwd)].joined(separator: " · "),
                                symbol: session.kind.symbol, tint: session.kind.tint, kind: .session(session), group: "Sessions",
                                mark: session.kind)
        }
        return sessions + (query.hasPrefix("@") ? [] : actions(search, store: store, quickCreate: quickCreate))
    }

    private static func messageItem(_ query: String, store: SessionStore) -> SwitcherItem? {
        guard query.hasPrefix("@"), let space = query.firstIndex(of: " ") else { return nil }
        let label = String(query[query.index(after: query.startIndex)..<space])
        let text = query[space...].trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let target = store.find(label) else { return nil }
        return SwitcherItem(id: "msg", title: "Send to \(target.label)", subtitle: text, symbol: "paperplane.fill",
                            tint: Palette.accent, kind: .message(target, text), group: "Message")
    }

    private static func actions(_ query: String, store: SessionStore, quickCreate: @escaping (SessionKind) -> Void) -> [SwitcherItem] {
        func send(_ selector: Selector) -> () -> Void { { NSApp.sendAction(selector, to: nil, from: nil) } }
        var all: [SwitcherItem] = []
        if let session = store.selected {
            if session.kind.isAgent {
                all.append(SwitcherItem(id: "review", title: "Review Changes", subtitle: "Diff, comments, commit", symbol: "plus.forwardslash.minus",
                                        tint: Tone.muted, kind: .action(send(#selector(AppDelegate.reviewSelected(_:))))))
            }
            if session.kind == .claude, session.spec.agentSessionId != nil {
                all.append(SwitcherItem(id: "fork", title: "Fork Conversation", subtitle: "A new agent continues from here",
                                        symbol: "arrow.triangle.branch", tint: Tone.muted, kind: .action { _ = store.fork(session) }))
            }
            if session.kind != .browser {
                all.append(SwitcherItem(id: "editor", title: "Open in \(Editors.preferred?.name ?? "Editor")", subtitle: shortPath(session.spec.workPath),
                                        symbol: "chevron.left.forwardslash.chevron.right", tint: Tone.muted,
                                        kind: .action { Editors.open(session.spec.workPath) }))
            }
            all += store.projectActions(for: session).map { action in
                SwitcherItem(id: "run-" + action.id, title: "Run \(action.name)", subtitle: action.command, symbol: action.symbol,
                             tint: Tone.muted, kind: .action { store.run(action, for: session) }, group: "Project")
            }
        }
        all += SessionKind.allCases.filter { $0 != .server }.map { kind in
            SwitcherItem(id: "new-\(kind.rawValue)", title: "New \(kind.displayName)", subtitle: "In the current folder",
                         symbol: kind.symbol, tint: kind.tint, kind: .action { quickCreate(kind) }, group: "Create", mark: kind)
        }
        all += store.recentlyClosed.prefix(5).map { spec in
            SwitcherItem(id: "reopen-\(spec.id)", title: "Reopen \(spec.label)", subtitle: spec.summary ?? shortPath(spec.cwd),
                         symbol: "arrow.uturn.backward", tint: spec.kind.tint, kind: .action { store.reopen(spec) }, group: "Create")
        }
        all += LayoutMode.allCases.map { mode in
            SwitcherItem(id: "layout-\(mode.rawValue)", title: "\(mode.title) Layout", subtitle: layoutDescription(mode),
                         symbol: mode.symbol, tint: Tone.muted, kind: .action { store.setLayout(mode) }, group: "Arrange")
        }
        all.append(SwitcherItem(id: "even", title: "Even Out Tiles", subtitle: "Give every tile the same space", symbol: "square.grid.2x2",
                                tint: Tone.muted, kind: .action(send(#selector(AppDelegate.evenOutTiles(_:)))), group: "Arrange"))
        guard !query.isEmpty else { return all }
        let ranked: [(item: SwitcherItem, score: Int, index: Int)] = all.enumerated()
            .map { (item: $0.element, score: fuzzyScore(query, $0.element.title), index: $0.offset) }
        let matches = ranked.filter { $0.score > 0 }.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.index < rhs.index
        }
        return matches.map { $0.item }
    }

    private static func layoutDescription(_ mode: LayoutMode) -> String {
        switch mode {
        case .focus: return "One session at a time"
        case .split: return "Your two most recent, side by side"
        case .grid: return "Every live session in view"
        }
    }

    private static func score(_ query: String, _ session: TerminalSession) -> Int {
        guard !query.isEmpty else { return 1 + (session.state.needsAttention ? 10 : 0) }
        let q = query.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        let label = fuzzyScore(q, session.label) * 3
        let other = fuzzyScore(q, [(session.summary ?? ""), session.spec.cwd, session.kind.rawValue].joined(separator: " ").lowercased())
        return max(label, other)
    }

    /// Subsequence match; consecutive and prefix matches score higher. 0 means no match.
    nonisolated static func fuzzyScore(_ query: String, _ text: String) -> Int {
        guard !query.isEmpty else { return 1 }
        let query = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let text = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        if text.hasPrefix(query) { return 100 }
        if text.contains(query) { return 60 }
        var score = 0
        var streak = 0
        var index = text.startIndex
        for char in query {
            guard let found = text[index...].firstIndex(of: char) else { return 0 }
            streak = found == index ? streak + 1 : 0
            let boundary = found == text.startIndex || !text[text.index(before: found)].isLetter
            score += 1 + streak * 2 + (boundary ? 5 : 0)
            index = text.index(after: found)
        }
        return score
    }
}

struct QuickSwitcherView: View {
    @ObservedObject var store: SessionStore
    let quickCreate: (SessionKind) -> Void
    let dismiss: () -> Void
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    var body: some View {
        let results = SwitcherModel.items(query: query, store: store, quickCreate: quickCreate)
        VStack(spacing: 0) {
            HStack(spacing: Space.m) {
                Image(systemName: "magnifyingglass")
                    .font(Typeface.title.weight(.regular))
                    .foregroundStyle(Tone.faint)
                TextField("Go to a session, run a command, or @name a message", text: $query)
                    .textFieldStyle(.plain)
                    .font(Typeface.title.weight(.regular))
                    .focused($focused)
                    .onSubmit { run(selection, in: results) }
                    .accessibilityLabel("Search sessions and commands")
            }
            .padding(.horizontal, Space.l)
            .frame(height: 52)
            Hairline()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if results.isEmpty {
                            EmptyMessage(symbol: "magnifyingglass", title: "No matches",
                                         detail: "Try a session name, an action, or a layout.")
                        }
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                            if index == 0 || results[index - 1].group != item.group {
                                SectionHeader(item.group)
                                    .padding(.horizontal, Space.s + 2)
                                    .padding(.top, index == 0 ? Space.xs : Space.m)
                                    .padding(.bottom, Space.xs)
                            }
                            Button { run(index, in: results) } label: {
                                row(item, selected: index == selection)
                            }
                            .buttonStyle(.plain)
                            .id(item.id)
                        }
                    }
                    .padding(Space.s)
                }
                .scrollIndicators(.never)
                .onChange(of: selection) {
                    if results.indices.contains(selection) { proxy.scrollTo(results[selection].id) }
                }
            }
            .frame(height: 340)
            Hairline()
            HStack(spacing: Space.m) {
                HStack(spacing: Space.xs) { KeyboardHint(keys: "↑↓"); Text("Move") }
                HStack(spacing: Space.xs) { KeyboardHint(keys: "↵"); Text("Open") }
                Spacer()
                Text("@name message · > actions only")
            }
            .font(Typeface.caption)
            .foregroundStyle(Tone.faint)
            .padding(.horizontal, Space.l)
            .frame(height: Size.barHeight + Space.xs)
        }
        .frame(width: 600)
        .foregroundStyle(Tone.text)
        .floatingSurface(fallback: Tone.deep)
        .clipShape(RoundedRectangle(cornerRadius: Radius.pane, style: .continuous))
        .onAppear { focused = true }
        .onChange(of: query) { selection = 0 }
        .onChange(of: results.map(\.id)) { selection = min(selection, max(results.count - 1, 0)) }
        .onKeyPress(.downArrow) { selection = min(selection + 1, max(results.count - 1, 0)); return .handled }
        .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
        .onKeyPress(.escape) { dismiss(); return .handled }
    }

    private func row(_ item: SwitcherItem, selected: Bool) -> some View {
        HStack(spacing: Space.m) {
            Group {
                if let mark = item.mark { KindMark(kind: mark, font: Typeface.body) } else { Image(systemName: item.symbol).font(Typeface.body) }
            }
            .foregroundStyle(item.tint)
            .frame(width: Space.l + Space.xs)
            Text(item.title).font(Typeface.body).lineLimit(1)
            if let subtitle = item.subtitle {
                Text(subtitle).font(Typeface.callout).foregroundStyle(Tone.faint).lineLimit(1)
            }
            Spacer(minLength: Space.s)
            if case .session(let session) = item.kind {
                StatusDot(state: session.state, size: 6)
            }
        }
        .padding(.horizontal, Space.s + 2)
        .frame(height: 32)
        .background(selected ? Tone.raised : .clear, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func run(_ index: Int, in current: [SwitcherItem]) {
        guard current.indices.contains(index) else { return }
        dismiss()
        switch current[index].kind {
        case .session(let session): store.select(session)
        case .message(let session, let text): _ = session.send(text, now: false)
        case .action(let action): action()
        }
    }
}

/// Borderless floating panel that closes when it loses focus.
final class SwitcherPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func resignKey() {
        super.resignKey()
        close()
    }
}
