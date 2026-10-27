import SwiftUI

/// The canvas before anything is running: the mark, one sentence, and the ways to start.
struct EmptyStateView: View {
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: Space.xl) {
                    VStack(spacing: Space.m) {
                        WaveMark().frame(width: 76, height: 76)
                        Text("Start an agent").font(Typeface.title)
                        Text("Pick what to open, or ask Sumi in the corner.")
                            .font(Typeface.body)
                            .foregroundStyle(Tone.muted)
                            .multilineTextAlignment(.center)
                    }
                    VStack(spacing: Space.xs) {
                        ForEach(SessionKind.allCases) { StartRow(kind: $0) }
                    }
                    .frame(maxWidth: 360)
                    HStack(spacing: Space.l) {
                        shortcut("⌘N", "New session")
                        shortcut("⌘P", "Commands")
                        shortcut("⌘J", "Next waiting")
                    }
                }
                .padding(Space.xl)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height)
            }
            .scrollIndicators(.never)
        }
        // No fill of its own: it sits on the canvas, which carries the theme.
        .foregroundStyle(Tone.text)
    }

    private func shortcut(_ keys: String, _ title: String) -> some View {
        HStack(spacing: Space.xs + 2) {
            KeyboardHint(keys: keys)
            Text(title).font(Typeface.caption).foregroundStyle(Tone.faint).fixedSize()
        }
    }
}

private struct StartRow: View {
    let kind: SessionKind
    @State private var hovering = false

    private var shortcut: String? {
        switch kind {
        case .claude: return "⇧⌘C"
        case .codex: return "⇧⌘X"
        case .shell: return "⌘T"
        case .browser: return "⇧⌘B"
        case .server: return nil
        }
    }

    var body: some View {
        Button {
            NSApp.sendAction(#selector(AppDelegate.newSessionOfKind(_:)), to: nil, from: KindSender(kind: kind))
        } label: {
            HStack(spacing: Space.m) {
                AgentAvatar(kind: kind)
                Text(kind.displayName).font(Typeface.body)
                Spacer()
                if let shortcut { KeyboardHint(keys: shortcut) }
            }
            .padding(.horizontal, Space.m)
            .frame(height: 40)
            .background(hovering ? Tone.raised : Tone.surface, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("Start \(kind.displayName)")
    }
}

/// Carries a kind through the responder chain from SwiftUI buttons.
final class KindSender: NSObject {
    let kind: SessionKind
    init(kind: SessionKind) { self.kind = kind }
}

@MainActor
enum NSHostingViewFactory {
    static func emptyState() -> NSView {
        let view = NSHostingView(rootView: EmptyStateView())
        view.autoresizingMask = [.width, .height]
        return view
    }
}
