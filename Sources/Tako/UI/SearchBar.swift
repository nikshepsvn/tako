import SwiftUI

/// ⌘F over the focused terminal. Uses libghostty's own search (scrollback included).
@MainActor
final class SearchModel: ObservableObject {
    @Published var needle = ""
    @Published var total: Int?
    @Published var selected: Int?
}

struct SearchBar: View {
    @ObservedObject var model: SearchModel
    let onChange: (String) -> Void
    let onNext: () -> Void
    let onPrevious: () -> Void
    let onClose: () -> Void
    @FocusState private var focused: Bool

    private var canNavigate: Bool { !model.needle.isEmpty && model.total != 0 }

    var body: some View {
        HStack(spacing: Space.s) {
            Image(systemName: "magnifyingglass")
                .font(Typeface.callout.weight(.medium))
                .foregroundStyle(Tone.muted)
            TextField("Find", text: $model.needle)
                .textFieldStyle(.plain)
                .font(Typeface.code)
                .focused($focused)
                .onSubmit { if canNavigate { onNext() } }
                .onChange(of: model.needle) { onChange(model.needle) }
                .onKeyPress(keys: [.return], phases: .down) { press in
                    guard press.modifiers.contains(.shift) else { return .ignored }
                    if canNavigate { onPrevious() }
                    return .handled
                }
                .frame(minWidth: 100, idealWidth: 176, maxWidth: 210)
                .accessibilityLabel("Find in terminal")
            Text(counter)
                .font(Typeface.caption.monospacedDigit())
                .foregroundStyle(model.total == 0 ? Palette.attention : Tone.faint)
                .frame(width: 72, alignment: .trailing)
                .accessibilityLabel(counter.isEmpty ? "Enter a search" : counter)
            HStack(spacing: 0) {
                IconButton(symbol: "chevron.up", help: "Previous match (⇧↵)", action: onPrevious).disabled(!canNavigate)
                IconButton(symbol: "chevron.down", help: "Next match (↵)", action: onNext).disabled(!canNavigate)
                IconButton(symbol: "xmark", help: "Close (Esc)", action: onClose).keyboardShortcut(.cancelAction)
            }
        }
        .foregroundStyle(Tone.text)
        .padding(.leading, Space.m)
        .padding(.trailing, Space.xs)
        .padding(.vertical, Space.xs + 2)
        .floatingSurface(cornerRadius: Radius.row + 2)
        .shadow(color: .black.opacity(0.3), radius: Space.m, y: Space.xs)
        .onAppear { focused = true }
    }

    private var counter: String {
        guard let total = model.total, !model.needle.isEmpty else { return "" }
        guard total > 0 else { return "No matches" }
        return "\(min((model.selected ?? 0) + 1, total)) of \(total)"
    }
}
