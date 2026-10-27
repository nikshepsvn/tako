import SwiftUI

/// Phone Mode's switch in the sidebar toolbar: a quiet icon like its neighbors when off. Clicking
/// it then turns Phone Mode on. While on it is gold-outlined with a small live dot, and clicking
/// it opens a popover with the details and the way to turn it off.
struct PhoneModeButton: View {
    @ObservedObject var store: SessionStore
    @State private var hovering = false
    @State private var showing = false

    var body: some View {
        let on = store.isPhoneModeOn
        Button {
            if on { showing.toggle() } else { store.startPhoneMode() }
        } label: {
            Image(systemName: "iphone")
                .font(Typeface.caption.weight(.semibold))
                .foregroundStyle(on ? Palette.attention : hovering ? Tone.text : Tone.muted)
                .frame(width: Size.iconButton, height: Size.iconButton)
                .background(on ? Palette.attention.opacity(0.14) : hovering ? Tone.raised : .clear,
                            in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .overlay {
                    if on {
                        RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                            .strokeBorder(Palette.attention, lineWidth: Size.hairline * 2)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if on { PhoneLiveDot(size: 6).offset(x: 2, y: -2) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(on ? "Phone Mode is on. Click for details or to turn it off."
                 : "Phone Mode: connects Sumi to your phone with Claude Remote Control. While you're away, agents don't wait for you here. Ordinary requests are allowed and Sumi handles the rest.")
        .accessibilityLabel("Phone Mode")
        .accessibilityValue(on ? "On" : "Off")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            if let since = store.phoneModeSince {
                PhoneModePopover(since: since) {
                    showing = false
                    store.setPhoneMode(false)
                }
            }
        }
        .onChange(of: on) { if !$0 { showing = false } }
    }
}

/// The green "live" dot; it breathes gently unless Reduce Motion is on.
private struct PhoneLiveDot: View {
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(Palette.running)
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(Tone.deep, lineWidth: Size.hairline))
            .opacity(dim && !reduceMotion ? 0.45 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { dim = true }
            }
            .accessibilityHidden(true)
    }
}

/// What Phone Mode is doing, and the off switch. There is no Copy link: Claude prints the Remote
/// Control link only in Sumi's terminal, and the app does not read it from there.
struct PhoneModePopover: View {
    let since: Date
    let turnOff: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(spacing: Space.s) {
                PhoneLiveDot(size: 8)
                Text("Phone Mode is on").font(Typeface.headline).foregroundStyle(Tone.text)
            }
            Text(Self.detail(since: since))
                .font(Typeface.callout)
                .foregroundStyle(Tone.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer(minLength: 0)
                Button("Turn Off", action: turnOff)
                    .buttonStyle(PanelButtonStyle(prominent: true, tint: Palette.attention))
                    .fixedSize()
            }
        }
        .padding(Space.m)
        .frame(width: 280)
    }

    static func detail(since: Date) -> String {
        "Remote Control since \(since.formatted(date: .omitted, time: .shortened)). Ordinary requests are allowed; questions and risky ones come to you."
    }
}
