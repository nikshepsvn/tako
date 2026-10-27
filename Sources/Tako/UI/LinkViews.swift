import Network
import SwiftUI

/// Tako Link's surfaces, kept quiet: Settings › Link (the switch, the name, Nearby and Paired),
/// the pairing code card, and in Sumi's header a chip that opens the conversation and the
/// messages waiting for the user's Send, Edit or Deny.

/// Settings › Link.
struct LinkSettings: View {
    @ObservedObject var link: TakoLink
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            HStack(alignment: .firstTextBaseline, spacing: Space.l) {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text("Tako Link: let Tako on this network find you").font(Typeface.body)
                    Text("Friends on the same Wi-Fi can pair with you; then your Sumis can message and ask each other. Nothing leaves this network, and only while both Takos are open.")
                        .font(Typeface.caption).foregroundStyle(Tone.muted).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Space.m)
                Toggle("", isOn: Binding(get: { link.settings.enabled }, set: { link.setEnabled($0) }))
                    .labelsHidden().toggleStyle(.switch)
            }
            HStack(spacing: Space.s) {
                Text("Shown as").font(Typeface.callout).foregroundStyle(Tone.muted)
                TextField(link.displayName, text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .onSubmit { link.setName(name) }
                Text(link.identity.fingerprint.prefix(8)).font(Typeface.codeSmall).foregroundStyle(Tone.faint)
                    .help("This Tako's key fingerprint")
                Spacer(minLength: 0)
            }
            if let pairing = link.pairing {
                LinkPairingCard(pairing: pairing, confirm: link.confirmPairing, cancel: link.cancelPairing)
            }
            if link.settings.enabled {
                peerSections
            }
            Text("To message a friend without a card, tell Sumi in your own words: “tell Alex: back in 10”. Anything Sumi writes itself waits for your Send.")
                .font(Typeface.caption).foregroundStyle(Tone.faint).fixedSize(horizontal: false, vertical: true)
        }
        .padding(Space.xl)
        .onAppear { name = link.settings.name ?? "" }
    }

    @ViewBuilder private var peerSections: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            SectionHeader("Paired") { if link.status != "On" { Text(link.status) } }
            if link.peers.isEmpty {
                Text("No one yet. Pair with someone nearby.").font(Typeface.callout).foregroundStyle(Tone.faint)
            }
            ForEach(link.peers) { peer in
                LinkPeerRow(name: peer.name, detail: link.isOnline(peer) ? "Online" : "Offline", online: link.isOnline(peer)) {
                    Button("Unpair") { link.unpair(peer) }
                }
            }
        }
        VStack(alignment: .leading, spacing: Space.xs) {
            SectionHeader("Nearby") { if !link.discovery.isEmpty { Text(link.discovery) } }
            let strangers = link.nearby.filter { near in !link.peers.contains { $0.fingerprint == near.fingerprint } }
            if strangers.isEmpty {
                Text("Looking for Takos with Link on…").font(Typeface.callout).foregroundStyle(Tone.faint)
            }
            ForEach(strangers) { near in
                LinkPeerRow(name: near.name, detail: String(near.fingerprint.prefix(8)), online: true) {
                    Button("Pair") { link.pair(with: near) }.disabled(link.isPairingBusy)
                }
            }
        }
    }
}

private struct LinkPeerRow<Action: View>: View {
    let name: String
    let detail: String
    let online: Bool
    @ViewBuilder var action: () -> Action

    var body: some View {
        HStack(spacing: Space.s) {
            Circle().fill(online ? Palette.running : Tone.faint).frame(width: Size.statusDot, height: Size.statusDot)
            Text(name).font(Typeface.body).foregroundStyle(Tone.text)
            Text(detail).font(Typeface.caption).foregroundStyle(Tone.faint)
            Spacer(minLength: Space.s)
            action().buttonStyle(PanelButtonStyle())
        }
        .padding(.horizontal, Space.s)
        .frame(minHeight: 32)
        .background(Tone.surface, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
    }
}

/// Both people see the same code; each confirms it matches the other screen.
struct LinkPairingCard: View {
    let pairing: TakoLink.Pairing
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text(title).font(Typeface.headline).foregroundStyle(Tone.text)
            if let code = pairing.code {
                Text(LinkPairingCode.display(code))
                    .font(.system(size: 28, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Tone.text)
                    .accessibilityLabel("Code \(code.map(String.init).joined(separator: " "))")
            }
            Text(detail).font(Typeface.caption).foregroundStyle(Tone.muted).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Space.s) {
                if pairing.phase == .comparing {
                    Button("Confirm", action: confirm).buttonStyle(PanelButtonStyle(prominent: true))
                }
                if pairing.phase != .paired {
                    Button(isFailed ? "Dismiss" : "Cancel", action: cancel).buttonStyle(PanelButtonStyle())
                }
            }
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tone.surface, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.row, style: .continuous).strokeBorder(Tone.hairline, lineWidth: Size.hairline))
    }

    private var isFailed: Bool { if case .failed = pairing.phase { return true } else { return false } }

    private var title: String {
        switch pairing.phase {
        case .connecting: return pairing.incoming ? "\(pairing.name) wants to pair" : "Asking \(pairing.name)…"
        case .comparing: return pairing.incoming ? "\(pairing.name) wants to pair" : "Pair with \(pairing.name)"
        case .waitingForPeer: return "Waiting for \(pairing.name) to confirm"
        case .paired: return "Paired with \(pairing.name)"
        case .failed: return "Pairing with \(pairing.name) didn't finish"
        }
    }

    private var detail: String {
        switch pairing.phase {
        case .connecting: return "Connecting…"
        case .comparing: return "Check that \(pairing.name)'s screen shows the same code, then confirm. A different code means someone else answered: cancel."
        case .waitingForPeer: return "You confirmed. It finishes when they confirm too."
        case .paired: return "Your Sumis can now message each other while both Takos are open."
        case .failed(let why): return why
        }
    }
}

/// A message Sumi wrote, waiting for the user: the exact text, to whom, and Send / Edit / Deny.
struct LinkApprovalCard: View {
    let approval: LinkApproval
    let send: (String?) -> Void
    let deny: () -> Void
    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.xs) {
                Image(systemName: "arrow.up.right").foregroundStyle(Palette.attention)
                Text("Sumi wants to \(verb) \(approval.peer.name)").font(Typeface.callout.weight(.semibold)).foregroundStyle(Tone.text)
                Spacer(minLength: 0)
                Tag(text: approval.message.kind.rawValue, tint: Palette.attention)
            }
            if editing {
                TextEditor(text: $draft)
                    .font(Typeface.body)
                    .scrollContentBackground(.hidden)
                    .padding(Space.xs)
                    .frame(minHeight: 60, maxHeight: 140)
                    .background(Tone.deep, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            } else {
                Text(approval.message.text ?? "")
                    .font(Typeface.body).foregroundStyle(Tone.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Space.s) {
                Button("Send") { send(editing ? draft : nil) }.buttonStyle(PanelButtonStyle(prominent: true))
                if !editing {
                    Button("Edit") { draft = approval.message.text ?? ""; editing = true }.buttonStyle(PanelButtonStyle())
                }
                Button("Deny", action: deny).buttonStyle(PanelButtonStyle())
            }
        }
        .padding(Space.m)
        .background(Tone.surface, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.row, style: .continuous).strokeBorder(Palette.attention.opacity(0.5), lineWidth: Size.hairline))
    }

    private var verb: String {
        switch approval.message.kind {
        case .ask: return "ask"
        case .answer: return "answer"
        default: return "message"
        }
    }
}

/// "Link 2" in Sumi's header while there's something to see: messages, approvals, a pairing.
struct LinkChip: View {
    @ObservedObject var link: TakoLink
    let store: SessionStore
    @State private var showsPanel = false

    var body: some View {
        if link.settings.enabled, !link.inbox.isEmpty || !link.approvals.isEmpty || link.pairing != nil {
            let waiting = link.approvals.count + (link.pairing?.phase == .comparing ? 1 : 0)
            Button { showsPanel.toggle() } label: {
                HStack(spacing: Space.xs) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                    Text(waiting > 0 ? "Link \(waiting)" : "Link").monospacedDigit()
                }
                .font(Typeface.caption.weight(.medium))
                .foregroundStyle(waiting > 0 ? Palette.attention : Tone.muted)
                .padding(.horizontal, Space.s)
                .frame(height: Size.iconButton)
                .background(showsPanel ? Tone.raised : Tone.surface, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(waiting > 0 ? "Tako Link: \(waiting) waiting for you" : "Tako Link: messages with friends' Sumis")
            .accessibilityLabel(waiting > 0 ? "Tako Link, \(waiting) waiting for you" : "Tako Link messages")
            .popover(isPresented: $showsPanel, arrowEdge: .bottom) {
                LinkPanel(link: link, send: { store.approveLink($0, text: $1) }, deny: { store.denyLink($0) })
                    .environment(\.colorScheme, .dark)
            }
            // A new message to approve opens the panel: Sumi is waiting on the user.
            .onChange(of: link.approvals.count) { old, new in if new > old { showsPanel = true } }
        }
    }
}

/// The chip's popover: what waits for the user, then the conversation.
struct LinkPanel: View {
    @ObservedObject var link: TakoLink
    /// Send an approval (with edited text); nil back means it's on its way.
    let send: (String, String?) -> String?
    let deny: (String) -> Void
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("Tako Link").font(Typeface.headline).foregroundStyle(Tone.text)
            if let pairing = link.pairing {
                LinkPairingCard(pairing: pairing, confirm: link.confirmPairing, cancel: link.cancelPairing)
            }
            ForEach(link.approvals) { approval in
                LinkApprovalCard(approval: approval, send: { error = send(approval.id, $0) }, deny: { deny(approval.id) })
            }
            if let error {
                Text(error).font(Typeface.caption).foregroundStyle(Palette.failed)
            }
            if !link.inbox.isEmpty {
                Hairline()
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.s) {
                        ForEach(link.inbox.reversed()) { LinkMessageRow(item: $0) }
                    }
                }
                .frame(maxHeight: 260)
            }
        }
        .padding(Space.m)
        .frame(width: 380)
        .background(Tone.deep)
    }
}

private struct LinkMessageRow: View {
    let item: LinkInboxItem

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            HStack(spacing: Space.xs) {
                Image(systemName: item.incoming ? "arrow.down.left" : "arrow.up.right")
                Text(item.incoming ? item.peerName : "To \(item.peerName)").fontWeight(.semibold)
                Text(phrase)
                Spacer(minLength: 0)
                Text(item.at, style: .time)
            }
            .font(Typeface.caption)
            .foregroundStyle(Tone.muted)
            Text(item.text).font(Typeface.callout).foregroundStyle(Tone.text)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var phrase: String {
        switch item.kind {
        case .ask: return item.incoming ? "asks" : "asked"
        case .answer: return item.incoming ? "answered" : "answer"
        default: return ""
        }
    }
}
