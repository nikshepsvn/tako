import SwiftUI

/// "Plan 3/7" in Sumi's header, shown only while Sumi has a plan. It opens the board.
struct SumiPlanChip: View {
    let plan: SumiPlan
    let store: SessionStore
    @State private var showsBoard = false

    var body: some View {
        if !plan.tasks.isEmpty {
            let done = plan.tasks.filter { $0.status == .done }.count
            let blocked = plan.tasks.contains { $0.status == .failed || $0.status == .blocked }
            Button { showsBoard.toggle() } label: {
                HStack(spacing: Space.xs) {
                    Image(systemName: "list.bullet.indent")
                    Text("Plan \(done)/\(plan.tasks.count)").monospacedDigit()
                }
                .font(Typeface.caption.weight(.medium))
                .foregroundStyle(blocked ? Palette.attention : Tone.muted)
                .padding(.horizontal, Space.s)
                .frame(height: Size.iconButton)
                .background(showsBoard ? Tone.raised : Tone.surface, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Sumi's plan: \(done) of \(plan.tasks.count) done" + (blocked ? ", some failed or blocked" : ""))
            .accessibilityLabel("Sumi's plan, \(done) of \(plan.tasks.count) done")
            .popover(isPresented: $showsBoard, arrowEdge: .bottom) {
                SumiPlanBoard(plan: plan, select: { label in
                    showsBoard = false
                    if let session = store.sessions.first(where: { $0.label == label }) { store.select(session) }
                })
                .environment(\.colorScheme, .dark)
            }
        }
    }
}

/// Sumi's task board, read-only: who does what, after what, and where each task stands. Sumi
/// edits it through its `plan` tool; Tako advances it on its own as owners finish.
struct SumiPlanBoard: View {
    let plan: SumiPlan
    /// An owner's label was clicked: show that agent.
    let select: (String) -> Void

    var body: some View {
        let done = plan.tasks.filter { $0.status == .done }.count
        let ready = Set(plan.ready.map(\.id))
        VStack(alignment: .leading, spacing: Space.s) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(plan.goal ?? "Sumi's plan").font(Typeface.headline).foregroundStyle(Tone.text)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Space.s) {
                    Meter(fraction: plan.tasks.isEmpty ? 0 : Double(done) / Double(plan.tasks.count))
                    Text("\(done) of \(plan.tasks.count) done").font(Typeface.caption).foregroundStyle(Tone.muted)
                        .monospacedDigit().fixedSize()
                }
            }
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    ForEach(plan.tasks, id: \.id) { task in
                        PlanTaskRow(task: task, isReady: ready.contains(task.id),
                                    openDeps: task.deps.filter { plan.task($0)?.status != .done }, select: select)
                    }
                }
            }
            .frame(maxHeight: 320)
            Text("Sumi keeps this board with its plan tool; tasks start when what they wait on is done.")
                .font(Typeface.caption).foregroundStyle(Tone.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Space.m)
        .frame(width: 380)
        .background(Tone.deep)
    }
}

private struct PlanTaskRow: View {
    let task: PlanTask
    let isReady: Bool
    let openDeps: [String]
    let select: (String) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Image(systemName: symbol).font(Typeface.caption.weight(.semibold)).foregroundStyle(tint).frame(width: 14)
            VStack(alignment: .leading, spacing: Space.xxs) {
                HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                    Text(task.id).font(Typeface.codeSmall).foregroundStyle(Tone.faint)
                    Text(task.title).font(Typeface.callout)
                        .foregroundStyle(task.status == .done ? Tone.faint : Tone.text)
                        .lineLimit(2)
                }
                HStack(spacing: Space.xs) {
                    if let owner = task.owner {
                        Button("@" + owner) { select(owner) }
                            .buttonStyle(.plain)
                            .font(Typeface.caption.weight(.medium))
                            .foregroundStyle(Tone.muted)
                            .help("Show @\(owner)")
                    } else if task.folder != nil {
                        Text("new agent").font(Typeface.caption).foregroundStyle(Tone.faint)
                    }
                    if !openDeps.isEmpty {
                        Text("after " + openDeps.joined(separator: ", ")).font(Typeface.caption).foregroundStyle(Tone.faint)
                    }
                    if let note = task.note {
                        Text(note).font(Typeface.caption).foregroundStyle(Tone.faint).lineLimit(1).truncationMode(.tail)
                            .help(note)
                    }
                }
            }
            Spacer(minLength: Space.xs)
            Text(word).font(Typeface.micro).foregroundStyle(tint).fixedSize()
        }
        .padding(.vertical, Space.xs)
        .padding(.horizontal, Space.xs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(task.id), \(task.title), \(word)")
    }

    private var word: String {
        if isReady { return "Ready" }
        switch task.status {
        case .todo: return "Waiting"
        case .running: return "Running"
        case .done: return "Done"
        case .failed: return "Failed"
        case .blocked: return "Blocked"
        }
    }

    private var symbol: String {
        if isReady { return "circle.dotted" }
        switch task.status {
        case .todo: return "circle"
        case .running: return "circle.lefthalf.filled"
        case .done: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .blocked: return "exclamationmark.circle"
        }
    }

    private var tint: Color {
        if isReady { return Palette.working }
        switch task.status {
        case .todo: return Tone.faint
        case .done: return Palette.running
        case .running: return Palette.working
        case .failed: return Palette.failed
        case .blocked: return Palette.attention
        }
    }
}
