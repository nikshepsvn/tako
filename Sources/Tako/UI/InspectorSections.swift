import SwiftUI

// Inspector sections for v2's coordination and health state. Each is quiet: it draws nothing
// until there is something to show.

/// The project's team board: who holds which files, and the notes agents left for each other.
struct TeamBoardSection: View {
    @ObservedObject var session: TerminalSession
    let store: SessionStore
    @State private var showsAllNotes = false

    private static let notesShown = 4

    var body: some View {
        // Read on each render of the session: claims expire, and the board is in memory (its
        // notes file is read once per project).
        let board = store.teamBoard(for: session)
        if !board.claims.isEmpty || !board.notes.isEmpty {
            VStack(alignment: .leading, spacing: Space.s) {
                SectionHeader("Team board") { Text(session.git?.project ?? "") }
                if !board.claims.isEmpty { claims(board) }
                if !board.notes.isEmpty { notes(board) }
            }
        }
    }

    private func claims(_ board: TeamBoard) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            ForEach(Array(board.claims.enumerated()), id: \.offset) { _, claim in
                let mine = claim.owner == session.id
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Image(systemName: "lock").font(Typeface.caption).foregroundStyle(mine ? Palette.working : Tone.faint)
                    Text(claim.path).font(Typeface.codeSmall).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: Space.xs)
                    Text("@" + claim.ownerLabel).font(Typeface.caption).foregroundStyle(mine ? Palette.working : Tone.muted)
                        .lineLimit(1).fixedSize()
                }
                .help("\(mine ? "This agent holds" : "@\(claim.ownerLabel) holds") \(claim.path) until \(claim.expires.formatted(date: .omitted, time: .shortened))")
            }
        }
    }

    private func notes(_ board: TeamBoard) -> some View {
        let recent = Array(board.notes.reversed())
        let shown = showsAllNotes ? recent : Array(recent.prefix(Self.notesShown))
        return VStack(alignment: .leading, spacing: Space.s) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, note in
                VStack(alignment: .leading, spacing: Space.xxs) {
                    HStack(spacing: Space.xs) {
                        Text("@" + note.author).font(Typeface.caption.weight(.semibold)).foregroundStyle(Tone.muted)
                        Text(elapsed(since: note.date) + " ago").font(Typeface.caption).foregroundStyle(Tone.faint)
                    }
                    Text(note.text).font(Typeface.callout).foregroundStyle(Tone.text)
                        .lineLimit(showsAllNotes ? nil : 3).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if recent.count > Self.notesShown {
                Button(showsAllNotes ? "Show fewer" : "Show all \(recent.count) notes") { showsAllNotes.toggle() }
                    .buttonStyle(.plain).font(Typeface.caption).foregroundStyle(Tone.muted)
            }
        }
    }
}

/// Requests the user answered in this project, which Sumi and Phone Mode answer the same way
/// next time. Forgetting one makes it ask again.
struct RememberedApprovalsSection: View {
    @ObservedObject var session: TerminalSession
    @ObservedObject var store: SessionStore
    @State private var expanded = false

    private static let collapsedCount = 3

    var body: some View {
        let remembered = store.rememberedApprovals(for: session)
        if !remembered.isEmpty {
            VStack(alignment: .leading, spacing: Space.s) {
                SectionHeader("Remembered answers") { Text(String(remembered.count)).monospacedDigit() }
                ForEach(expanded ? remembered : Array(remembered.prefix(Self.collapsedCount)), id: \.key) { item in
                    HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                        Text(item.key).font(Typeface.codeSmall).lineLimit(1).truncationMode(.middle).help(item.key)
                        Spacer(minLength: Space.xs)
                        Text(ApprovalMemory.precedent(item.record))
                            .font(Typeface.caption)
                            .foregroundStyle(item.record.always ? Palette.running : Tone.faint)
                            .lineLimit(1).fixedSize()
                        IconButton(symbol: "xmark", help: "Forget: ask again next time") {
                            store.forgetApproval(item.key, for: session)
                        }
                    }
                }
                if remembered.count > Self.collapsedCount {
                    Button(expanded ? "Show fewer" : "Show all \(remembered.count)") { expanded.toggle() }
                        .buttonStyle(.plain).font(Typeface.caption).foregroundStyle(Tone.muted)
                }
            }
        }
    }
}

/// Tako's own memory, and the processes it started that no terminal owns any more, with a way
/// to stop them. The scan runs only when asked.
struct TakoHealthSection: View {
    @ObservedObject var steward: Steward
    let store: SessionStore
    @State private var orphans: [OrphanProcess]?
    @State private var scanning = false
    @State private var stopping: Set<pid_t> = []

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            SectionHeader("Tako")
            if steward.takoBytes > 0 {
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Text("Memory").foregroundStyle(Tone.muted).frame(width: 72, alignment: .leading)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(steward.takoBytes), countStyle: .memory))
                        .monospacedDigit()
                        .foregroundStyle(steward.takoBytes >= TakoFootprint.warnBytes ? Palette.attention : Tone.text)
                    Spacer(minLength: 0)
                }
                .help(steward.takoBytes >= TakoFootprint.warnBytes
                      ? "Tako itself has grown large. Restart it when nothing is mid-task; sessions resume."
                      : "Tako's own memory, browsers and agents not included")
            }
            if let orphans {
                orphanList(orphans)
            } else {
                ActionRow(symbol: "magnifyingglass", title: scanning ? "Looking…" : "Find Stray Processes") { scan() }
                    .help("Dev servers, browsers and tools Tako started whose terminal has closed")
                    .disabled(scanning)
                    .padding(.horizontal, -Space.s)
            }
        }
    }

    @ViewBuilder private func orphanList(_ found: [OrphanProcess]) -> some View {
        if found.isEmpty {
            Text("No stray processes: everything Tako started belongs to an open terminal.")
                .foregroundStyle(Tone.faint).fixedSize(horizontal: false, vertical: true)
        } else {
            let total = found.compactMap(\.memory).reduce(0, +)
            HStack {
                Text("\(found.count) stray process\(found.count == 1 ? "" : "es")" + (total > 0 ? " · " + Self.size(total) : ""))
                    .foregroundStyle(Palette.attention)
                Spacer(minLength: Space.xs)
                Button("Stop All") { stop(found) }.buttonStyle(PanelButtonStyle())
            }
            ForEach(found, id: \.pid) { orphan in
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        Text(orphan.command).font(Typeface.codeSmall).lineLimit(1).truncationMode(.middle).help(orphan.command)
                        Text(detail(orphan)).font(Typeface.caption).foregroundStyle(Tone.faint).lineLimit(1)
                    }
                    Spacer(minLength: Space.xs)
                    Button(stopping.contains(orphan.pid) ? "Stopping…" : "Stop") { stop([orphan]) }
                        .buttonStyle(PanelButtonStyle())
                        .disabled(stopping.contains(orphan.pid))
                }
            }
        }
        Button("Look Again") { scan() }.buttonStyle(.plain).font(Typeface.caption).foregroundStyle(Tone.muted)
    }

    private func detail(_ orphan: OrphanProcess) -> String {
        let started = Date(timeIntervalSince1970: TimeInterval(orphan.start) / 1_000_000)
        return (["pid \(orphan.pid)", Orphans.age(Date().timeIntervalSince(started)), orphan.memory.map(Self.size), orphan.why]
            .compactMap { $0 }).joined(separator: " · ")
    }

    private static func size(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    private func scan() {
        scanning = true
        store.scanOrphans { found in
            scanning = false
            orphans = found
        }
    }

    /// The user clicked Stop: TERM, then KILL after a grace period, then a fresh list.
    private func stop(_ chosen: [OrphanProcess]) {
        stopping.formUnion(chosen.map(\.pid))
        Orphans.stop(chosen) {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    stopping.subtract(chosen.map(\.pid))
                    scan()
                }
            }
        }
    }
}

/// Messages this agent sent other agents, and what became of each: the receipts Tako typed
/// back to it, kept where the user can see them. Newest first; only shown once it has sent one.
struct SentMessagesSection: View {
    let entries: [SentMessageLog.Entry]
    @State private var expanded = false

    private static let collapsedCount = 4

    var body: some View {
        let recent = entries.sorted { $0.sentAt > $1.sentAt }
        let open = recent.filter { !$0.outcome.isFinal }.count
        VStack(alignment: .leading, spacing: Space.s) {
            SectionHeader("Sent messages") {
                Text(open > 0 ? "\(open) not landed" : String(recent.count)).monospacedDigit()
            }
            ForEach(expanded ? recent : Array(recent.prefix(Self.collapsedCount))) { entry in
                row(entry)
            }
            if recent.count > Self.collapsedCount {
                Button(expanded ? "Show fewer" : "Show all \(recent.count)") { expanded.toggle() }
                    .buttonStyle(.plain).font(Typeface.caption).foregroundStyle(Tone.muted)
            }
        }
    }

    private func row(_ entry: SentMessageLog.Entry) -> some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Image(systemName: "paperplane").font(Typeface.caption).foregroundStyle(Tone.faint)
                Text("@" + entry.target).font(Typeface.callout.weight(.medium)).lineLimit(1)
                if let id = entry.messageID {
                    Text(id).font(Typeface.codeSmall).foregroundStyle(Tone.faint)
                }
                Spacer(minLength: Space.xs)
                Tag(text: entry.outcome.title, tint: Self.tint(entry.outcome))
                Text(elapsed(since: entry.sentAt)).font(Typeface.caption.monospacedDigit()).foregroundStyle(Tone.faint)
            }
            Text(entry.preview).font(Typeface.caption).foregroundStyle(Tone.muted).lineLimit(1).truncationMode(.tail)
                .padding(.leading, Space.l + Space.xs)
            if case .dropped(let why) = entry.outcome {
                Text("Not delivered: " + why).font(Typeface.caption).foregroundStyle(Palette.failed).lineLimit(2)
                    .padding(.leading, Space.l + Space.xs)
            }
        }
        .help(Self.help(entry))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("To \(entry.target), \(entry.outcome.title), \(elapsed(since: entry.sentAt)) ago: \(entry.preview)")
    }

    static func tint(_ outcome: SentMessageLog.Outcome) -> Color {
        switch outcome {
        case .delivered: return Palette.running
        case .queued, .channelUnconfirmed: return Tone.muted
        case .stillWaiting, .typedInstead: return Palette.attention
        case .dropped: return Palette.failed
        }
    }

    private static func help(_ entry: SentMessageLog.Entry) -> String {
        let what: String
        switch entry.outcome {
        case .delivered: what = "Reached @\(entry.target)."
        case .queued: what = "Waiting in @\(entry.target)'s queue; it lands when @\(entry.target) is free."
        case .channelUnconfirmed: what = "Handed to @\(entry.target)'s channel; Tako types it if Claude doesn't confirm it."
        case .stillWaiting: what = "Still queued after a long while; it lands when @\(entry.target) is free."
        case .typedInstead: what = "The channel never confirmed it, so Tako typed it into @\(entry.target) instead."
        case .dropped(let why): what = "Not delivered: \(why)."
        }
        let changed = entry.updatedAt > entry.sentAt ? " Updated \(elapsed(since: entry.updatedAt)) ago." : ""
        return "Sent \(entry.sentAt.formatted(date: .omitted, time: .shortened)). " + what + changed
    }
}
