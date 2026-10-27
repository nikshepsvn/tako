import SwiftUI

/// @@ in a terminal: a small list of the other sessions at the cursor. Picking one types its
/// name, so referring to another terminal never means remembering or spelling it.
struct MentionPickerView: View {
    @ObservedObject var store: SessionStore
    /// The terminal the name goes into; it isn't offered.
    let origin: TerminalSession
    let pick: (TerminalSession) -> Void
    let dismiss: () -> Void
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    private var results: [TerminalSession] {
        let others = store.sessions.filter { $0.id != origin.id }
        let search = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !search.isEmpty else { return others }
        return others
            .map { (session: $0, score: SwitcherModel.fuzzyScore(search, $0.label)) }
            .filter { $0.score > 0 }
            .sorted { $0.score > $1.score }
            .map(\.session)
    }

    var body: some View {
        let results = results
        VStack(spacing: 0) {
            TextField("Name a session", text: $query)
                .textFieldStyle(.plain)
                .font(Typeface.body)
                .focused($focused)
                .onSubmit { choose(selection, in: results) }
                .padding(.horizontal, Space.m)
                .frame(height: 34)
                .accessibilityLabel("Filter sessions")
            Hairline()
            VStack(spacing: 0) {
                if results.isEmpty {
                    Text(store.sessions.count > 1 ? "No matches" : "No other sessions yet")
                        .font(Typeface.callout)
                        .foregroundStyle(Tone.faint)
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                ForEach(Array(results.prefix(8).enumerated()), id: \.element.id) { index, session in
                    Button { choose(index, in: results) } label: { row(session, selected: index == selection) }
                        .buttonStyle(.plain)
                }
            }
            .padding(Space.xs)
        }
        .frame(width: 340)
        .foregroundStyle(Tone.text)
        .floatingSurface(fallback: Tone.deep)
        .clipShape(RoundedRectangle(cornerRadius: Radius.pane, style: .continuous))
        .onAppear { focused = true }
        .onChange(of: query) { selection = 0 }
        .onKeyPress(.downArrow) { selection = min(selection + 1, max(min(results.count, 8) - 1, 0)); return .handled }
        .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
        .onKeyPress(.escape) { dismiss(); return .handled }
    }

    private func row(_ session: TerminalSession, selected: Bool) -> some View {
        HStack(spacing: Space.s) {
            Image(systemName: session.kind.symbol)
                .font(Typeface.callout)
                .foregroundStyle(session.kind.tint)
                .frame(width: Space.l)
            Text(session.label).font(Typeface.body).lineLimit(1)
            if let summary = session.summary {
                Text(summary).font(Typeface.caption).foregroundStyle(Tone.faint).lineLimit(1)
            }
            Spacer(minLength: Space.s)
            StatusDot(state: session.state, size: 6)
        }
        .padding(.horizontal, Space.s)
        .frame(height: 28)
        .background(selected ? Tone.raised : .clear, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func choose(_ index: Int, in current: [TerminalSession]) {
        guard current.indices.contains(index) else { return }
        pick(current[index])
    }
}
