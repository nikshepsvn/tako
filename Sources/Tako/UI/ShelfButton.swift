import SwiftUI

/// Servers and parked tiles while the sidebar is hidden: one small pill in the canvas's corner
/// that lists them. With the sidebar shown they're already there, so the pill stays away and the
/// tiles keep the whole canvas.
struct ShelfButton: View {
    @ObservedObject var store: SessionStore
    @State private var showing = false

    static func servers(_ store: SessionStore) -> [TerminalSession] {
        store.sessions.filter { $0.kind == .server && !$0.pinnedToGrid && !$0.isMinimized }
    }
    static func parked(_ store: SessionStore) -> [TerminalSession] { store.sessions.filter(\.isMinimized) }

    var body: some View {
        let servers = Self.servers(store)
        let parked = Self.parked(store)
        Button { showing.toggle() } label: {
            HStack(spacing: Space.xs + 2) {
                if let first = servers.first {
                    StatusDot(state: first.state, size: 5)
                    Text(first.label).lineLimit(1)
                    if let port = first.ports.first {
                        Text(":" + String(port)).font(Typeface.micro.monospaced()).foregroundStyle(Palette.running)
                    }
                    if servers.count > 1 { Text("+\(servers.count - 1)").foregroundStyle(Tone.muted) }
                }
                if !parked.isEmpty {
                    if !servers.isEmpty { Text("·").foregroundStyle(Tone.faint) }
                    Text("\(parked.count) parked").foregroundStyle(Tone.muted)
                }
            }
            .modifier(ChipChrome(active: showing))
        }
        .buttonStyle(.plain)
        .help("Servers and parked tiles")
        .accessibilityLabel("\(servers.count) servers, \(parked.count) parked tiles")
        .popover(isPresented: $showing, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: Space.xs) {
                if !servers.isEmpty {
                    Text("Servers").font(Typeface.caption).foregroundStyle(Tone.faint)
                    ForEach(servers) { ServerChip(session: $0, store: store) }
                }
                if !parked.isEmpty {
                    Text("Parked").font(Typeface.caption).foregroundStyle(Tone.faint).padding(.top, servers.isEmpty ? 0 : Space.xs)
                    ForEach(parked) { ShelvedChip(session: $0, store: store) }
                }
            }
            .padding(Space.m)
            .background(Tone.deep)
        }
    }
}

/// A chip in the shelf's list: quiet fill, brighter on hover.
private struct ChipChrome: ViewModifier {
    var active = false
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .font(Typeface.caption.weight(.medium))
            .foregroundStyle(Tone.text)
            .padding(.horizontal, Space.s)
            .frame(height: Size.iconButton)
            .background(active || hovering ? Tone.raised : Tone.surface, in: RoundedRectangle(cornerRadius: Radius.control + 1, style: .continuous))
            .onHover { hovering = $0 }
    }
}

private struct ShelvedChip: View {
    @ObservedObject var session: TerminalSession
    let store: SessionStore

    var body: some View {
        Button { store.select(session) } label: {
            HStack(spacing: Space.xs + 2) {
                KindMark(kind: session.kind, font: Typeface.micro).foregroundStyle(session.kind.tint)
                Text(session.label).lineLimit(1)
                StatusDot(state: session.state, size: 5)
            }
            .modifier(ChipChrome())
        }
        .buttonStyle(.plain)
        .help("Restore \(session.label) · \(session.statusWord)")
        .accessibilityLabel("Restore \(session.label), \(session.statusWord)")
        .contextMenu { Button("Restore") { store.select(session) } }
    }
}

private struct ServerChip: View {
    @ObservedObject var session: TerminalSession
    let store: SessionStore
    @State private var showing = false
    @State private var logs = ""

    var body: some View {
        Button {
            logs = session.surface.readText(lastLines: 80)
            showing.toggle()
        } label: {
            HStack(spacing: Space.xs + 2) {
                StatusDot(state: session.state, size: 5)
                Text(session.label).lineLimit(1)
                ForEach(session.ports.prefix(2), id: \.self) { port in
                    Text(":" + String(port)).font(Typeface.micro.monospaced()).foregroundStyle(Palette.running)
                }
            }
            .modifier(ChipChrome(active: showing))
        }
        .buttonStyle(.plain)
        .help("Logs and actions for \(session.label)")
        .accessibilityLabel("Server \(session.label), \(session.statusWord)")
        .popover(isPresented: $showing, arrowEdge: .top) { detail }
        .contextMenu {
            Button("Show as Tile") { session.pinnedToGrid = true; store.select(session) }
            if let port = session.ports.first {
                Button("Open in Browser") { open(port) }
                Button("Preview") { PreviewWindowController.show(port: port) }
            }
            Button("Restart") { session.restart() }
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(spacing: Space.s) {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(session.label).font(Typeface.headline)
                    Text(shortPath(session.spec.cwd))
                        .font(Typeface.codeSmall)
                        .foregroundStyle(Tone.faint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                HStack(spacing: Space.xs) {
                    StatusDot(state: session.state, size: 6)
                    Text(session.statusWord)
                }
                .font(Typeface.caption)
                .foregroundStyle(Tone.muted)
            }
            ScrollView {
                Text(logs.isEmpty ? "No output yet." : logs)
                    .font(Typeface.codeSmall)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(Space.m)
            }
            .frame(height: 260)
            .background(Color(nsColor: Theme.terminalBackground), in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
            .foregroundStyle(Color(nsColor: Theme.terminalForeground))
            HStack(spacing: Space.s) {
                Button("Restart") { session.restart(); showing = false }
                Button("Refresh") { logs = session.surface.readText(lastLines: 80) }
                if let port = session.ports.first {
                    Button("Open in Browser") { open(port) }
                    Button("Preview") { PreviewWindowController.show(port: port) }
                }
                Spacer()
                Button("Show as Tile") {
                    session.pinnedToGrid = true
                    showing = false
                    store.select(session)
                }
                .buttonStyle(PanelButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
            }
            .buttonStyle(PanelButtonStyle())
        }
        .padding(Space.l)
        .frame(width: 520)
        .foregroundStyle(Tone.text)
        .background(Tone.deep)
    }

    private func open(_ port: Int) {
        if let url = URL(string: "http://localhost:\(port)") { NSWorkspace.shared.open(url) }
    }
}
