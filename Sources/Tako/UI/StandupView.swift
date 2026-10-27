import SwiftUI

/// Every agent on one card, the way Sumi's `standup` sees them: what needs you, what failed,
/// what's working and what's done, each with how long, what it's doing, its todos, diff,
/// blocker and cost. Answers "update? ETA?" without asking anyone. Picking a row goes to that
/// agent and closes the card.
///
/// It computes only while open: rows come from state the sessions already hold, and git is
/// read once, off the main thread, when it opens. Nothing ticks; ages are as of the last change.
struct StandupView: View {
    @ObservedObject var store: SessionStore
    let dismiss: () -> Void
    @State private var git: [UUID: (stat: DiffStat?, dirty: Int?)] = [:]
    @State private var selection = 0
    @FocusState private var focused: Bool

    static let width: CGFloat = 440

    var body: some View {
        let rows = store.standupRows(git: git)
        VStack(spacing: 0) {
            header(rows)
            Hairline()
            if rows.isEmpty {
                EmptyMessage(symbol: "person.2", title: "No agents yet",
                             detail: "Start one with ⌘N or from the sidebar; its progress shows here.")
                    .frame(height: 160)
            } else {
                list(rows)
            }
            Hairline()
            footer
        }
        .frame(width: Self.width)
        .foregroundStyle(Tone.text)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear {
            focused = true
            store.probeStandupGit { git = $0 }
        }
        .onChange(of: rows.map(\.id)) { selection = min(selection, max(rows.count - 1, 0)) }
        .onKeyPress(.downArrow) { selection = min(selection + 1, max(rows.count - 1, 0)); return .handled }
        .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
        .onKeyPress(.return) { open(rows.indices.contains(selection) ? rows[selection] : nil); return .handled }
        .onKeyPress(.escape) { dismiss(); return .handled }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Standup")
    }

    private func header(_ rows: [StandupRow]) -> some View {
        let cost = rows.compactMap(\.cost).reduce(0, +)
        let counts = Dictionary(grouping: rows, by: \.group).mapValues(\.count)
        var summary = ["\(rows.count) agent\(rows.count == 1 ? "" : "s")"]
        if let waiting = counts[.needsYou] { summary.append("\(waiting) need\(waiting == 1 ? "s" : "") you") }
        if cost > 0 { summary.append(String(format: "$%.2f", cost)) }
        return HStack(spacing: Space.s) {
            Text("Standup").font(Typeface.headline)
            Spacer(minLength: Space.s)
            Text(summary.joined(separator: " · ")).font(Typeface.caption.monospacedDigit()).foregroundStyle(Tone.faint)
        }
        .padding(.horizontal, Space.l)
        .frame(height: 40)
    }

    private func list(_ rows: [StandupRow]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index == 0 || rows[index - 1].group != row.group {
                            SectionHeader(row.group.title) { Text(String(rows.filter { $0.group == row.group }.count)).monospacedDigit() }
                                .padding(.horizontal, Space.s + 2)
                                .padding(.top, index == 0 ? Space.xs : Space.m)
                                .padding(.bottom, Space.xs)
                        }
                        Button { open(row) } label: {
                            StandupRowView(row: row, selected: index == selection)
                        }
                        .buttonStyle(.plain)
                        .id(row.id)
                    }
                }
                .padding(Space.s)
            }
            .scrollIndicators(.never)
            .frame(height: Self.listHeight(rows))
            .onChange(of: selection) { if rows.indices.contains(selection) { proxy.scrollTo(rows[selection].id) } }
        }
    }

    /// Tall enough for its rows up to a cap, so a short standup is a short card. An estimate:
    /// a longer list than it allows scrolls.
    static func listHeight(_ rows: [StandupRow]) -> CGFloat {
        var height = Space.s * 2
        for (index, row) in rows.enumerated() {
            if index == 0 || rows[index - 1].group != row.group { height += index == 0 ? 24 : 32 }
            height += 30
            if let blocker = row.blocker { height += blocker.count > 60 ? 32 : 17 } else if row.doing != nil { height += 17 }
            if row.todosTotal > 0 || row.diff != nil || (row.uncommitted ?? 0) > 0 { height += 18 }
        }
        return min(height, 460)
    }

    private var footer: some View {
        HStack(spacing: Space.m) {
            HStack(spacing: Space.xs) { KeyboardHint(keys: "↑↓"); Text("Move") }
            HStack(spacing: Space.xs) { KeyboardHint(keys: "↵"); Text("Go to agent") }
            Spacer()
            HStack(spacing: Space.xs) { KeyboardHint(keys: "⌘J"); Text("Next waiting") }
        }
        .font(Typeface.caption)
        .foregroundStyle(Tone.faint)
        .padding(.horizontal, Space.l)
        .frame(height: Size.barHeight)
    }

    private func open(_ row: StandupRow?) {
        guard let row, let session = store.sessions.first(where: { $0.id == row.id }) else { return }
        dismiss()
        store.select(session)
    }
}

/// One agent: name, state and for how long, cost; then what it's doing or what blocks it; then
/// its todos, diff and uncommitted files.
struct StandupRowView: View {
    let row: StandupRow
    var selected = false
    var now = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            HStack(spacing: Space.s) {
                StatusDot(state: row.state, size: 6)
                Text(row.label).font(Typeface.headline).lineLimit(1).truncationMode(.middle)
                Text(stateText).font(Typeface.caption.monospacedDigit()).foregroundStyle(stateColor).lineLimit(1).fixedSize()
                Spacer(minLength: Space.s)
                if let cost = row.cost, cost > 0 {
                    Text(String(format: "$%.2f", cost)).font(Typeface.caption.monospacedDigit()).foregroundStyle(Tone.faint)
                }
            }
            if let blocker = row.blocker {
                Text(blocker)
                    .font(Typeface.callout)
                    .foregroundStyle(row.group == .failed ? Palette.failed : row.group == .needsYou ? Palette.attention : Tone.muted)
                    .lineLimit(2)
                    .padding(.leading, Space.l)
            } else if let doing = row.doing {
                Text(doing).font(Typeface.codeSmall).foregroundStyle(Tone.muted).lineLimit(1).truncationMode(.tail)
                    .padding(.leading, Space.l)
            }
            if hasFacts {
                HStack(spacing: Space.s) {
                    if row.todosTotal > 0 {
                        Tag(text: "\(row.todosDone)/\(row.todosTotal) todos", tint: row.todosDone == row.todosTotal ? Palette.running : Tone.muted)
                            .help(row.currentTodo.map { "Now: " + $0 } ?? "All todos done")
                    }
                    if let diff = row.diff {
                        DiffCount(added: diff.added, removed: diff.removed)
                        Text("\(diff.files) file\(diff.files == 1 ? "" : "s")").font(Typeface.micro).foregroundStyle(Tone.faint)
                    }
                    if let dirty = row.uncommitted, dirty > 0 {
                        Text("\(dirty) uncommitted").font(Typeface.micro).foregroundStyle(Tone.faint)
                    }
                    if let current = row.currentTodo, row.todosTotal > 0 {
                        Text(current).font(Typeface.micro).foregroundStyle(Tone.faint).lineLimit(1).truncationMode(.tail)
                    }
                }
                .padding(.leading, Space.l)
            }
        }
        .padding(.horizontal, Space.s + 2)
        .padding(.vertical, Space.s - 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Tone.raised : .clear, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var hasFacts: Bool { row.todosTotal > 0 || row.diff != nil || (row.uncommitted ?? 0) > 0 }

    private var stateText: String {
        let since = elapsed(since: row.since, now: now)
        if row.asleep { return "Asleep \(since)" }
        switch row.state {
        case .needsInput: return "Waiting \(since)"
        case .working: return "Working \(since)"
        case .starting: return "Starting \(since)"
        case .idle: return "Done \(since) ago"
        default: return row.state.phrase + " · \(since) ago"
        }
    }

    private var stateColor: Color {
        switch row.group {
        case .needsYou: return Palette.attention
        case .failed: return Palette.failed
        case .working: return Palette.working
        case .done: return Tone.faint
        }
    }

    private var accessibilityText: String {
        var parts = [row.label, stateText]
        if let blocker = row.blocker { parts.append(blocker) } else if let doing = row.doing { parts.append(doing) }
        if row.todosTotal > 0 { parts.append("\(row.todosDone) of \(row.todosTotal) todos") }
        if let diff = row.diff { parts.append("\(diff.added) added, \(diff.removed) removed") }
        if let cost = row.cost, cost > 0 { parts.append(String(format: "$%.2f", cost)) }
        return parts.joined(separator: ", ")
    }
}
