import SwiftUI

/// The footer's machine button: a quiet chip icon, or Tako's size in gold once Tako itself has
/// grown past the point where a restart is worth it. Either way it opens the machine popover.
/// It redraws only when the steward's 64 MB-rounded reading changes.
struct MachineButton: View {
    @ObservedObject var steward: Steward
    let store: SessionStore
    @State private var showing = false
    @State private var hovering = false

    var body: some View {
        let heavy = steward.takoBytes >= TakoFootprint.warnBytes
        Button { showing.toggle() } label: {
            Group {
                if heavy {
                    Tag(text: "Tako " + ByteCountFormatter.string(fromByteCount: Int64(steward.takoBytes), countStyle: .memory),
                        tint: Palette.attention)
                } else {
                    Image(systemName: "memorychip")
                        .font(Typeface.caption.weight(.semibold))
                        .foregroundStyle(hovering ? Tone.text : Tone.muted)
                        .frame(width: Size.iconButton, height: Size.iconButton)
                        .background(hovering ? Tone.raised : .clear, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(heavy ? "Tako itself is using a lot of memory. Restart it when nothing is mid-task; sessions resume. Click for the machine."
                    : "Machine: Tako's memory, the browser, agents, MCP helpers and stray processes")
        .accessibilityLabel("Machine")
        .accessibilityValue(heavy ? "Tako is using a lot of memory" : "")
        .popover(isPresented: $showing, arrowEdge: .top) {
            MachinePopover(store: store)
        }
    }
}

/// Tako, the browser, the agents and the Mac's memory on one card, read once as it opens. It
/// only reads, except Stop on a stray process.
struct MachinePopover: View {
    let store: SessionStore
    /// Given for snapshots; otherwise read from the steward on open.
    var preview: (readout: MachineReadout, trend: MachineReadout.Trend?, orphans: [OrphanProcess]?)? = nil
    @State private var readout: MachineReadout?
    @State private var trend: MachineReadout.Trend?
    @State private var doctor: String?
    @State private var runningDoctor = false

    static let width: CGFloat = 360

    var body: some View {
        let shown = readout ?? preview?.readout ?? MachineReadout()
        let trend = self.trend ?? preview?.trend
        ScrollView {
            VStack(alignment: .leading, spacing: Space.m) {
                header(shown)
                Hairline()
                takoSection(shown, trend: trend)
                browserSection(shown)
                agentsSection(shown)
                if !shown.helpers.isEmpty { helpersSection(shown) }
                Hairline()
                VStack(alignment: .leading, spacing: Space.s) {
                    SectionHeader("Stray processes")
                    StrayProcessesView(store: store, initial: preview?.orphans)
                }
                Hairline()
                doctorSection
            }
            .padding(Space.l)
            .font(Typeface.callout)
        }
        .scrollIndicators(.never)
        .frame(width: Self.width)
        .frame(maxHeight: 620)
        .fixedSize(horizontal: false, vertical: doctor == nil)
        .foregroundStyle(Tone.text)
        .onAppear(perform: load)
    }

    private func load() {
        guard preview == nil else { return }
        let current = store.machineReadout()
        readout = current
        store.loadFootprintTrend(now: current.takoBytes) { trend = $0 }
    }

    private func header(_ shown: MachineReadout) -> some View {
        HStack(spacing: Space.s) {
            Text("Machine").font(Typeface.headline)
            Spacer(minLength: Space.s)
            Tag(text: pressureText(shown.pressure), tint: pressureTint(shown.pressure))
                .help("How hard macOS is squeezing memory")
            if shown.totalBytes > 0 {
                Text("\(size(shown.freeBytes)) free of \(size(shown.totalBytes))")
                    .font(Typeface.caption.monospacedDigit()).foregroundStyle(Tone.faint)
            }
        }
    }

    private func takoSection(_ shown: MachineReadout, trend: MachineReadout.Trend?) -> some View {
        let heavy = shown.takoBytes >= TakoFootprint.warnBytes
        return VStack(alignment: .leading, spacing: Space.xs) {
            row("Tako", size(shown.takoBytes), tint: heavy ? Palette.attention : Tone.text,
                detail: shown.uptime > 0 ? "up " + SessionStore.duration(shown.uptime) : nil)
            if let trend {
                Text("24 h: \(size(trend.start)) → \(size(shown.takoBytes)), peak \(size(trend.peak))" + (trend.growing ? " · growing" : ""))
                    .font(Typeface.caption.monospacedDigit())
                    .foregroundStyle(trend.growing ? Palette.attention : Tone.faint)
                    .padding(.leading, Self.labelWidth + Space.s)
            }
            if heavy {
                Text("Restart Tako when nothing is mid-task; sessions resume.")
                    .font(Typeface.caption).foregroundStyle(Palette.attention)
                    .padding(.leading, Self.labelWidth + Space.s)
            }
        }
    }

    private func browserSection(_ shown: MachineReadout) -> some View {
        row("Browser", shown.browser.running ? size(shown.browser.bytes) : "not started",
            tint: shown.browser.running ? Tone.text : Tone.faint,
            detail: shown.browser.running ? "\(shown.browser.processes) process\(shown.browser.processes == 1 ? "" : "es") (CEF)" : nil)
    }

    private func agentsSection(_ shown: MachineReadout) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            row("Agents", shown.agentCount == 0 ? "none" : size(shown.agentBytes), tint: shown.agentCount == 0 ? Tone.faint : Tone.text,
                detail: shown.agentCount == 0 ? nil : "\(shown.agentCount) live")
            ForEach(Array(shown.topAgents.enumerated()), id: \.offset) { _, agent in
                HStack(spacing: Space.s) {
                    Text("@" + agent.label).lineLimit(1).truncationMode(.middle).foregroundStyle(Tone.muted)
                    Spacer(minLength: Space.xs)
                    Text(size(agent.bytes)).font(Typeface.caption.monospacedDigit()).foregroundStyle(Tone.faint)
                }
                .padding(.leading, Self.labelWidth + Space.s)
            }
        }
    }

    private func helpersSection(_ shown: MachineReadout) -> some View {
        let over = shown.helpers.contains { $0.count > Doctor.helperLimit }
        return VStack(alignment: .leading, spacing: Space.xs) {
            row("MCP helpers", "\(shown.helpers.map(\.count).reduce(0, +))", tint: over ? Palette.attention : Tone.text,
                detail: over ? "over \(Doctor.helperLimit) in one agent is a leak" : "per agent")
            FlowLayout(spacing: Space.xs) {
                ForEach(Array(shown.helpers.prefix(8).enumerated()), id: \.offset) { _, helper in
                    Tag(text: "@\(helper.label) \(helper.count)", tint: helper.count > Doctor.helperLimit ? Palette.attention : Tone.muted)
                }
            }
            .padding(.leading, Self.labelWidth + Space.s)
        }
        .help("Tako's MCP servers (ht mcp, ht mcp-lazy, ht browser-mcp) running in each agent's process tree")
    }

    private var doctorSection: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            if let doctor {
                SectionHeader("Doctor") { Text("last 24 h") }
                Text(doctor)
                    .font(Typeface.codeSmall)
                    .foregroundStyle(Tone.muted)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ActionRow(symbol: "stethoscope", title: runningDoctor ? "Checking…" : "Run Doctor",
                          detail: "ht doctor") { runDoctor() }
                    .help("Tako's health over the last day: hooks, messages, launches, gc, footprint, helpers, channels")
                    .disabled(runningDoctor)
                    .padding(.horizontal, -Space.s)
            }
        }
    }

    private func runDoctor() {
        runningDoctor = true
        store.doctor { report in
            runningDoctor = false
            doctor = report
        }
    }

    private static let labelWidth: CGFloat = 84

    private func row(_ label: String, _ value: String, tint: Color, detail: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Text(label).foregroundStyle(Tone.muted).frame(width: Self.labelWidth, alignment: .leading)
            Text(value).monospacedDigit().foregroundStyle(tint)
            if let detail { Text(detail).font(Typeface.caption).foregroundStyle(Tone.faint).lineLimit(1) }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func size(_ bytes: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory) }

    private func pressureText(_ pressure: MemoryPressure) -> String {
        switch pressure {
        case .normal: return "Memory normal"
        case .warning: return "Memory tight"
        case .critical: return "Memory critical"
        }
    }

    private func pressureTint(_ pressure: MemoryPressure) -> Color {
        switch pressure {
        case .normal: return Palette.running
        case .warning: return Palette.attention
        case .critical: return Palette.failed
        }
    }
}
