import AppKit
import Combine
import SwiftUI

/// A session's terminal plus, in split/grid layouts, a slim header naming it. The surface is
/// reparented into whichever tile shows it; the process keeps running regardless.
///
/// Focus and attention have separate, static indicators. Idle chrome does no animation work.
@MainActor
final class TileView: NSView {
    let session: TerminalSession
    private let content = NSView()
    private let header: TileHeaderHost
    private let model: TileHeaderModel
    private let border = CALayer()
    private let headerRule = CALayer()
    /// Waiting or finished-and-unseen: a 1px underline below the header, and a light streak that
    /// sweeps along it once on arrival.
    private let headerUnderline = CALayer()
    private let sweep = CAGradientLayer()
    private var recapHost: NSHostingView<RecapBanner>?
    private var closeBarHost: NSHostingView<CloseBar>?
    private var searchHost: NSHostingView<SearchBar>?
    let search = SearchModel()

    private static let headerHeight: CGFloat = Size.barHeight
    private static let radius: CGFloat = Radius.pane
    private var isVisible = false
    private var lifted = false
    private var dropTarget = false

    var showsHeader = false {
        didSet {
            guard showsHeader != oldValue else { return }
            header.isHidden = !showsHeader
            model.setVisible(isVisible && showsHeader, session: session)
            needsLayout = true
            updateChrome()
        }
    }
    var isFocusedTile = false {
        didSet {
            guard isFocusedTile != oldValue else { return }
            model.focused = isFocusedTile
            updateChrome()
        }
    }
    /// The chrome last drawn, so status refreshes that change nothing visible cost nothing.
    private var drawnChrome: Chrome?

    private struct Chrome: Equatable {
        let header: Bool
        let focused: Bool
        let attention: Bool
        let finished: Bool
        let dropTarget: Bool
    }

    init(session: TerminalSession, actions: TileActions) {
        self.session = session
        self.model = TileHeaderModel(session: session)
        self.header = TileHeaderHost(rootView: TileHeader(model: model, actions: actions))
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        header.sizingOptions = []
        content.wantsLayer = true
        header.wantsLayer = true
        applyTheme()
        content.layer?.cornerCurve = .continuous
        content.layer?.masksToBounds = true
        addSubview(content)

        border.borderWidth = 1
        border.cornerCurve = .continuous
        border.zPosition = 20
        headerRule.backgroundColor = Ink.hairline.cgColor
        headerRule.zPosition = 9
        headerUnderline.zPosition = 10
        headerUnderline.isHidden = true
        sweep.zPosition = 11
        sweep.isHidden = true
        sweep.startPoint = CGPoint(x: 0, y: 0.5)
        sweep.endPoint = CGPoint(x: 1, y: 0.5)
        content.layer?.addSublayer(headerRule)
        content.layer?.addSublayer(headerUnderline)
        content.layer?.addSublayer(sweep)
        layer?.addSublayer(border)

        content.addSubview(header)
        header.isHidden = true
        attachSurface()
        updateChrome()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Called after a restart swaps the session's surface.
    func attachSurface() {
        content.subviews.filter { $0 is any SessionSurface && $0 !== session.surface }.forEach { $0.removeFromSuperview() }
        if session.surface.superview !== content {
            session.surface.removeFromSuperview()
            content.addSubview(session.surface, positioned: .below, relativeTo: header)
            session.surface.setOccluded(!isVisible)
            needsLayout = true
        }
    }

    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        isHidden = !visible
        session.surface.setOccluded(!visible)
        model.setVisible(visible && showsHeader, session: session)
        if visible { updateChrome() }
    }

    func refreshAttention() {
        model.refresh(session)
        updateChrome()
    }

    /// Picked up by its header: drawn above the other tiles with a deeper shadow.
    func setLifted(_ lifted: Bool) {
        self.lifted = lifted
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.zPosition = lifted ? 100 : 0
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOffset = CGSize(width: 0, height: -6)
        layer?.shadowRadius = lifted ? 20 : 0
        layer?.shadowOpacity = lifted ? 0.45 : 0
        layer?.shadowPath = lifted ? CGPath(roundedRect: bounds, cornerWidth: Self.radius, cornerHeight: Self.radius, transform: nil) : nil
        CATransaction.commit()
    }

    /// Another tile is being dragged over this one; dropping trades their places.
    func setDropTarget(_ target: Bool) {
        guard target != dropTarget else { return }
        dropTarget = target
        updateChrome()
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        if content.frame != bounds { content.frame = bounds }
        let headerHeight = showsHeader ? Self.headerHeight : 0
        let headerFrame = NSRect(x: 0, y: max(0, bounds.height - headerHeight), width: bounds.width, height: headerHeight)
        if header.frame != headerFrame { header.frame = headerFrame }
        let surfaceFrame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - headerHeight))
        if session.surface.frame != surfaceFrame { session.surface.frame = surfaceFrame }
        if let recapHost {
            let width = max(0, min(bounds.width - 24, 560))
            let height = recapHost.fittingSize.height
            recapHost.frame = NSRect(x: (bounds.width - width) / 2, y: bounds.height - headerHeight - height - 12, width: width, height: height)
        }
        if let closeBarHost {
            let width = max(0, min(bounds.width - 24, 640))
            closeBarHost.frame = NSRect(x: (bounds.width - width) / 2, y: 12, width: width, height: closeBarHost.fittingSize.height)
        }
        if let searchHost {
            let size = searchHost.fittingSize
            searchHost.frame = NSRect(x: bounds.width - size.width - 12, y: bounds.height - headerHeight - size.height - 10,
                                      width: size.width, height: size.height)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        border.frame = bounds
        headerRule.frame = NSRect(x: 0, y: bounds.height - headerHeight - 1, width: bounds.width, height: 1)
        headerRule.isHidden = !showsHeader
        headerUnderline.frame = headerRule.frame
        sweep.bounds = CGRect(x: 0, y: 0, width: max(60, bounds.width * 0.3), height: 2)
        sweep.position = CGPoint(x: sweep.position.x, y: bounds.height - headerHeight)
        CATransaction.commit()
    }

    // MARK: - Chrome

    /// The theme's fills; called again when View › Theme changes.
    func applyTheme() {
        let fill = Theme.window.tileFill(terminal: Theme.terminalBackground).cgColor
        content.layer?.backgroundColor = fill
        header.layer?.backgroundColor = fill
        drawnChrome = nil
        updateChrome()
    }

    private func updateChrome() {
        let chrome = Chrome(header: showsHeader, focused: isFocusedTile,
                            attention: session.state.needsAttention, finished: session.finishedUnseen, dropTarget: dropTarget)
        guard chrome != drawnChrome else { return }
        let previous = drawnChrome
        drawnChrome = chrome
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.layer?.cornerRadius = Self.radius
        border.cornerRadius = Self.radius
        // One ring at a time, strongest meaning wins: drop target, then focus, then rest.
        if chrome.dropTarget {
            border.borderColor = Ink.focus.withAlphaComponent(0.8).cgColor
            border.borderWidth = 2
        } else if isFocusedTile && showsHeader {
            border.borderColor = Ink.focus.cgColor
            border.borderWidth = 1
        } else {
            border.borderColor = Ink.hairline.cgColor
            border.borderWidth = 1
        }
        // Waiting is gold, finished-and-unseen is green; both clear once seen. The border is untouched.
        let tint: (color: NSColor, rule: CGFloat)? =
            chrome.attention ? (NSColor(Palette.attention), 0.7)
            : chrome.finished ? (NSColor(Palette.running), 0.6) : nil
        headerUnderline.isHidden = tint == nil || !chrome.header
        sweep.removeAllAnimations()
        sweep.isHidden = true
        if let tint {
            headerUnderline.backgroundColor = tint.color.withAlphaComponent(tint.rule).cgColor
            // The streak plays only on arrival into the state, never on layout or an unrelated refresh.
            let arrived = previous != nil && chrome.header && !chrome.focused
                && (previous?.attention != chrome.attention || previous?.finished != chrome.finished)
            if arrived && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { playSweep(color: tint.color) }
        }
        headerRule.backgroundColor = Ink.hairline.cgColor
        CATransaction.commit()
    }

    /// One bright streak left to right along the header's bottom edge.
    private func playSweep(color: NSColor) {
        sweep.colors = [color.withAlphaComponent(0).cgColor, color.cgColor, color.withAlphaComponent(0).cgColor]
        sweep.isHidden = false
        let half = sweep.bounds.width / 2
        let slide = CABasicAnimation(keyPath: "position.x")
        slide.fromValue = -half
        slide.toValue = bounds.width + half
        slide.duration = 2.2
        slide.timingFunction = CAMediaTimingFunction(name: .easeOut)
        sweep.position.x = bounds.width + half
        sweep.add(slide, forKey: "sweep")
        // Hide it once it has left, so it never rests at the edge.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.3) { [weak self] in
            guard let self, self.sweep.animation(forKey: "sweep") == nil else { return }
            self.sweep.isHidden = true
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        guard frame.size != newSize else { return }
        super.setFrameSize(newSize)
        if lifted {
            layer?.shadowPath = CGPath(roundedRect: NSRect(origin: .zero, size: newSize), cornerWidth: Self.radius, cornerHeight: Self.radius, transform: nil)
        }
    }

    // MARK: - Overlays

    /// "Since you left 14m ago: 6 edits, tests passed, finished: …" when returning to an agent.
    func showRecapIfNeeded() {
        let events = session.timeline.filter { $0.date > session.lastViewedAt }
        guard session.kind.isAgent, !events.isEmpty, Date().timeIntervalSince(session.lastViewedAt) > 120 else { return }
        recapHost?.removeFromSuperview()
        let host = NSHostingView(rootView: RecapBanner(
            since: session.lastViewedAt, sentence: Recap.sentence(for: events),
            onDismiss: { [weak self] in self?.recapHost?.removeFromSuperview(); self?.recapHost = nil }))
        content.addSubview(host, positioned: .above, relativeTo: nil)
        recapHost = host
        needsLayout = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self, weak host] in
            guard let self, let host, self.recapHost === host else { return }
            NSAnimationContext.runAnimationGroup { $0.duration = 0.3; host.animator().alphaValue = 0 } completionHandler: {
                MainActor.assumeIsolated {
                    host.removeFromSuperview()
                    if self.recapHost === host { self.recapHost = nil }
                }
            }
        }
    }

    /// The question before closing something that holds work; replaces any earlier one.
    func showCloseBar(_ model: CloseBarModel) {
        hideCloseBar()
        let host = NSHostingView(rootView: CloseBar(model: model))
        content.addSubview(host, positioned: .above, relativeTo: nil)
        closeBarHost = host
        needsLayout = true
    }

    func hideCloseBar() {
        closeBarHost?.removeFromSuperview()
        closeBarHost = nil
    }

    func showSearch() {
        if let searchHost { searchHost.isHidden = false; window?.makeFirstResponder(searchHost); return }
        let host = NSHostingView(rootView: SearchBar(
            model: search,
            onChange: { [weak self] needle in self?.session.surface.performBinding("search:" + needle) },
            onNext: { [weak self] in self?.session.surface.performBinding("navigate_search:next") },
            onPrevious: { [weak self] in self?.session.surface.performBinding("navigate_search:previous") },
            onClose: { [weak self] in self?.hideSearch() }))
        content.addSubview(host, positioned: .above, relativeTo: nil)
        searchHost = host
        needsLayout = true
    }

    func hideSearch() {
        session.surface.performBinding("end_search")
        search.needle = ""
        search.total = nil
        search.selected = nil
        searchHost?.removeFromSuperview()
        searchHost = nil
        window?.makeFirstResponder(session.surface)
    }
}

@MainActor
final class TileHeaderModel: ObservableObject {
    @Published var focused = false
    @Published private(set) var isVisible = false
    @Published private(set) var snapshot: TileHeaderSnapshot
    private var subscription: AnyCancellable?
    private var refreshQueued = false

    init(session: TerminalSession) {
        snapshot = TileHeaderSnapshot(session: session)
        // A poll can publish many unrelated metrics. Read only once, after those values land.
        subscription = session.objectWillChange.sink { [weak self, weak session] _ in
            guard let self, self.isVisible, !self.refreshQueued else { return }
            self.refreshQueued = true
            DispatchQueue.main.async { [weak self, weak session] in
                guard let self else { return }
                self.refreshQueued = false
                if let session { self.refresh(session) }
            }
        }
    }

    func setVisible(_ visible: Bool, session: TerminalSession) {
        guard visible != isVisible else { return }
        if visible { update(TileHeaderSnapshot(session: session)) }
        isVisible = visible
    }

    func refresh(_ session: TerminalSession) {
        guard isVisible else { return }
        update(TileHeaderSnapshot(session: session))
    }

    private func update(_ next: TileHeaderSnapshot) {
        if snapshot != next { snapshot = next }
    }
}

/// Only fields actually drawn by a header participate in its invalidation.
struct TileHeaderSnapshot: Equatable {
    let label: String
    let kind: SessionKind
    let state: AgentState
    let stateChangedAt: Date
    let statusWord: String
    let ports: [Int]
    let summary: String?
    let overlap: OverlapBadge?
    let asleep: Bool
    /// Finished and not yet looked at.
    let finished: Bool
    /// Sumi handles its waits; the tag's tooltip.
    let delegation: String?

    @MainActor init(session: TerminalSession) {
        overlap = session.overlapBadge
        delegation = session.delegation?.help
        label = session.label
        kind = session.kind
        state = session.state
        stateChangedAt = session.stateChangedAt
        statusWord = session.statusWord
        ports = session.ports
        asleep = session.isAsleep
        finished = session.finishedUnseen
        if case .needsInput(let reason) = session.state {
            summary = session.pendingRequest ?? reason
        } else {
            summary = session.kind.isAgent ? (session.agentStatus ?? session.summary) : session.foregroundProcess
        }
    }
}

/// What a tile's header can ask of the canvas.
@MainActor
struct TileActions {
    var select: () -> Void
    var zoom: () -> Void
    var minimize: () -> Void
    /// Pop the tile out into its own window.
    var detach: () -> Void
    var close: () -> Void
    var wake: () -> Void
    /// Header drag in progress: translation from where it started (SwiftUI, y down).
    var drag: (CGSize) -> Void
    var dragEnded: () -> Void
}

/// Tiles reach the window's top edge, under the titlebar band: a press on the header drags the
/// tile, never the window.
final class TileHeaderHost: NSHostingView<TileHeader> {
    override var mouseDownCanMoveWindow: Bool { false }
}

struct TileHeader: View {
    @ObservedObject var model: TileHeaderModel
    let actions: TileActions
    @State private var hovering = false

    var body: some View {
        if model.isVisible {
            GeometryReader { geometry in header(compact: geometry.size.width < 360) }
        }
    }

    private func header(compact: Bool) -> some View {
        let snapshot = model.snapshot
        return HStack(spacing: Space.s) {
            KindMark(kind: snapshot.kind)
                .foregroundStyle(snapshot.kind.tint)
                .frame(width: Space.l)
            Text(snapshot.label)
                .font(Typeface.callout.weight(.semibold))
                .foregroundStyle(model.focused ? Tone.text : Tone.muted)
                .lineLimit(1)
                .layoutPriority(1)
            if !compact, let summary = snapshot.summary {
                Text(summary)
                    .font(Typeface.caption)
                    .foregroundStyle(snapshot.state.needsAttention ? Palette.attention : Tone.faint)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: Space.xs)
            if snapshot.state.needsAttention {
                StatusPill(text: "Needs you", tint: Palette.attention)
            } else if snapshot.finished {
                StatusPill(text: "✓ Done", tint: Palette.running)
            }
            if let overlap = snapshot.overlap, !compact {
                Tag(text: overlap.title, tint: Palette.attention).help(overlap.detail)
            }
            if let delegation = snapshot.delegation, !compact {
                Tag(text: "Sumi", tint: Palette.accent).help(delegation)
            }
            if !snapshot.ports.isEmpty, !compact { PortChips(ports: snapshot.ports, compact: true) }
            if snapshot.kind == .browser {
                BrowserDriverBadge(label: snapshot.label)
            } else if hovering || compact {
                controls(compact: compact)
            } else if snapshot.asleep {
                AsleepMark().help("Asleep · type or send a message to wake it")
            } else {
                StatusDot(state: snapshot.state, size: 6)
                    .help(snapshot.statusWord)
            }
        }
        .padding(.leading, Space.m)
        .padding(.trailing, Space.xs)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The fill is the host's layer (TileView.applyTheme), so a theme change needs no re-render.
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: actions.zoom)
        .onTapGesture(perform: actions.select)
        // Drag the header to move the tile; drop it on another to trade places.
        .gesture(DragGesture(minimumDistance: 5, coordinateSpace: .global)
            .onChanged { actions.drag($0.translation) }
            .onEnded { _ in actions.dragEnded() })
        .contextMenu {
            Button("Focus", action: actions.select)
            Button("Zoom", action: actions.zoom)
            Button("Minimize to Shelf", action: actions.minimize)
            Button("Detach", action: actions.detach)
            if snapshot.asleep { Button("Wake", action: actions.wake) }
            Divider()
            Button("Close", action: actions.close)
        }
        .help("Drag to move · double-click to zoom")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(snapshot.label), \(snapshot.statusWord)\(model.focused ? ", focused" : "")")
    }

    @ViewBuilder private func controls(compact: Bool) -> some View {
        if compact {
            Menu {
                Button("Zoom", action: actions.zoom)
                Button("Minimize to Shelf", action: actions.minimize)
                Button("Detach", action: actions.detach)
                Divider()
                Button("Close", action: actions.close)
            } label: {
                Image(systemName: "ellipsis").font(Typeface.caption.weight(.semibold)).foregroundStyle(Tone.muted)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Tile actions")
        } else {
            HStack(spacing: 0) {
                IconButton(symbol: "minus", help: "Minimize to shelf (⇧⌘M)", action: actions.minimize)
                IconButton(symbol: "arrow.up.left.and.arrow.down.right", help: "Zoom (⌘⏎)", action: actions.zoom)
                IconButton(symbol: "xmark", help: "Close (⌘W)", action: actions.close)
            }
        }
    }
}

/// The arrival marker in a header: text in the color on a 15% tint of it. Never truncates; the title and summary give way first.
private struct StatusPill: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(Typeface.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, Space.s)
            .padding(.vertical, 1)
            .background(tint.opacity(0.15), in: Capsule())
            .lineLimit(1)
            .fixedSize()
            .layoutPriority(2)
    }
}

/// A browser's tile shows who is driving it, not a process status.
struct BrowserDriverBadge: View {
    let label: String

    var body: some View {
        if let activity = AgentBrowser.shared.activity, activity.browser == label {
            Tag(text: "@\(activity.agent) · \(activity.action)", tint: Palette.working)
                .transition(.opacity)
        }
    }
}

struct RecapBanner: View {
    let since: Date
    let sentence: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            Image(systemName: "clock.arrow.circlepath")
                .font(Typeface.body.weight(.semibold))
                .foregroundStyle(Palette.working)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("Since you left, \(elapsed(since: since)) ago").font(Typeface.caption.weight(.semibold)).foregroundStyle(Tone.muted)
                Text(sentence).font(Typeface.body).foregroundStyle(Tone.text).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            IconButton(symbol: "xmark", help: "Dismiss", action: onDismiss)
        }
        .padding(Space.m)
        .floatingSurface()
        .shadow(color: .black.opacity(0.3), radius: Space.m, y: Space.xs)
    }
}
