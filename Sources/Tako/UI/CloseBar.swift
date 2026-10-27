import SwiftUI

/// What the bar is asking about and what each button does. Built by the window controller so the
/// bar itself is only layout.
@MainActor
final class CloseBarModel: ObservableObject {
    /// "3 files aren't committed and 2 commits aren't in main yet." and/or "Still working."
    let message: String
    /// Nil when merging isn't on offer (the agent is still running, or it isn't a worktree).
    let mergeTitle: String?
    let leaveTitle: String
    @Published var busy = false
    @Published var error: String?
    var onKeep: () -> Void = {}
    var onMerge: () -> Void = {}
    var onLeave: () -> Void = {}

    init(message: String, mergeTitle: String?, leaveTitle: String) {
        self.message = message
        self.mergeTitle = mergeTitle
        self.leaveTitle = leaveTitle
    }
}

/// The one question Tako asks before closing something that holds work. It sits on the agent's
/// own tile, never as a popup. Keep open is the default, and Escape does it.
struct CloseBar: View {
    @ObservedObject var model: CloseBarModel

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.s) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Palette.attention)
                Text(model.message).font(Typeface.body.weight(.semibold)).foregroundStyle(Tone.text)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            if let error = model.error {
                Text(error).font(Typeface.caption).foregroundStyle(Palette.attention).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Space.s) {
                Button("Keep open") { model.onKeep() }
                    .buttonStyle(PanelButtonStyle(prominent: true))
                    .keyboardShortcut(.cancelAction)
                if let merge = model.mergeTitle {
                    Button(merge) { model.onMerge() }.buttonStyle(PanelButtonStyle())
                }
                Button(model.leaveTitle) { model.onLeave() }.buttonStyle(PanelButtonStyle())
                if model.busy { ProgressView().controlSize(.small) }
            }
            .disabled(model.busy)
        }
        .padding(Space.m)
        .floatingSurface()
        .shadow(color: .black.opacity(0.3), radius: Space.m, y: -Space.xs)
    }
}
