import AppKit
import SwiftUI
import XCTest
@testable import Tako

/// Opt-in native visual QA. Fixtures never launch a PTY, restore sessions, or persist state.
/// Run with TEST_RUNNER_TAKO_CAPTURE_UI=/absolute/output/directory in xcodebuild's environment.
@MainActor
final class InterfaceSnapshotTests: XCTestCase {
    func testCaptureInterface() throws {
        guard let path = ProcessInfo.processInfo.environment["TAKO_CAPTURE_UI"], !path.isEmpty else {
            throw XCTSkip("Set TAKO_CAPTURE_UI to capture native interface previews.")
        }
        guard GhosttyRuntime.shared.app == nil else {
            throw XCTSkip("Visual fixtures require an inactive Ghostty runtime.")
        }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let sessions = fixtures()
        defer { sessions.forEach { $0.terminate() } }
        let store = SessionStore(previewSessions: sessions)
        store.inspectorTab = .info
        let actions = inertActions

        try capture(SidebarView(store: store, actions: actions), size: NSSize(width: 336, height: 900),
                    name: "sidebar", output: output)
        try capture(InspectorView(store: store, actions: actions), size: NSSize(width: 360, height: 900),
                    name: "inspector-info", output: output)
        store.inspectorTab = .activity
        try capture(InspectorView(store: store, actions: actions), size: NSSize(width: 360, height: 740),
                    name: "inspector-activity", output: output)
        store.inspectorTab = .info
        try capture(QuickSwitcherView(store: store, quickCreate: { _ in }, dismiss: {}),
                    size: NSSize(width: 600, height: 440), name: "command-palette", output: output)

        let patch = PatchLine.parse("""
        @@ -10,7 +10,8 @@ struct Workspace {
             let sessions: [Session]
        -    var layout: Layout = .grid
        -    var focused: Session?
        +    var layout: LayoutTree = LayoutTree()
        +    /// The tile with keyboard focus.
        +    var focused: Session.ID?
             func arrange() {
        -        grid.reflow()
        +        layout.reconcile(visible: sessions.map(\\.id), in: bounds)
             }
        """)
        try capture(DiffText(lines: patch, sideBySide: false, commented: [12], onComment: { _ in })
                        .frame(width: 520, height: 240), size: NSSize(width: 520, height: 240), name: "diff-unified", output: output)
        try capture(DiffText(lines: patch, sideBySide: true, commented: [], onComment: { _ in })
                        .frame(width: 720, height: 260), size: NSSize(width: 720, height: 260), name: "diff-split", output: output)

        try capture(QuickAskView(store: store, dismiss: {}), size: NSSize(width: 640, height: 130),
                    name: "quick-ask", output: output)

        try capture(SettingsView(pane: .general, signIn: { _ in }), size: NSSize(width: 560, height: 360),
                    name: "settings", output: output)
        try capture(PhoneModePopover(since: Date(timeIntervalSinceReferenceDate: 813_402_000), turnOff: {}),
                    size: NSSize(width: 300, height: 170), name: "phone-mode", output: output)

        var draft = NewSessionDraft()
        draft.kind = .codex
        draft.label = "feature-lab"
        draft.cwd = "/workspace/atlas"
        draft.worktree = true
        try capture(NewSessionView(draft: draft, recentDirectories: ["/workspace/atlas", "/workspace/api"], defaultName: "alpha",
                                   onCreate: { _ in }, onCancel: {}),
                    size: NSSize(width: 584, height: 710), name: "new-session", output: output)
        try capture(EmptyStateView(), size: NSSize(width: 420, height: 760),
                    name: "empty-narrow", output: output)
        try capture(EmptyStateView(), size: NSSize(width: 1060, height: 760),
                    name: "empty-wide", output: output)
        try captureWorkspace(store: store, output: output)
        try captureWorkspace(store: SessionStore(previewSessions: []), output: output,
                             name: "workspace-empty", showInspector: false, captureNarrow: false)
    }

    private var inertActions: SessionActions {
        SessionActions(newSession: {}, rename: { _ in }, releaseLabel: { _ in }, restart: { _ in },
                       close: { _ in }, review: { _ in })
    }

    private func fixtures() -> [TerminalSession] {
        let now = Date()
        let builder = sample("design-system", kind: .claude, branch: "feat/interface", state: .working)
        builder.agentStatus = "Refining the workspace experience"
        builder.activity = "Edit: components/workspace.tsx"
        builder.usage = UsageSnapshot(costUSD: 0.84, contextPercent: 34, model: "Opus")
        builder.tasks = TaskProgress(subjects: ["layout": "Polish workspace layout", "tests": "Check keyboard navigation"],
                                     completed: ["layout"], order: ["layout", "tests"])
        builder.spec.agentSessionId = "84c601df-792d-4af1-9d19-ff863c0dd4e7"
        builder.runningSubagents = ["a1": Subagent(type: "Explore", startedAt: now.addingTimeInterval(-150)),
                                    "a2": Subagent(type: "code-reviewer", startedAt: now.addingTimeInterval(-40))]
        builder.timeline = [
            TimelineEvent(date: now.addingTimeInterval(-240), kind: .prompt, text: "Make the workspace feel focused, clear, and fast."),
            TimelineEvent(date: now.addingTimeInterval(-180), kind: .edit, text: "Updated workspace layout and spacing."),
            TimelineEvent(date: now.addingTimeInterval(-120), kind: .tool, text: "pnpm test --filter workspace"),
            TimelineEvent(date: now.addingTimeInterval(-90), kind: .test, text: "Tests passed · 42 checks"),
            TimelineEvent(date: now.addingTimeInterval(-30), kind: .edit, text: "Refining keyboard navigation and focus states."),
        ]
        builder.lastViewedAt = now.addingTimeInterval(-200)
        terminalPixels(builder, lines: [
            ("claude · design-system", .accent),
            ("", .normal),
            ("› Refine the workspace experience", .normal),
            ("", .normal),
            ("  ✓ Workspace layout and spacing", .success),
            ("  ✓ Clearer session states", .success),
            ("  ✓ 42 checks passed", .success),
            ("", .normal),
            ("  Editing components/workspace.tsx", .normal),
            ("  Reviewing keyboard focus behavior…", .muted),
        ])

        let waiting = sample("api-contracts", kind: .codex, branch: "feat/api", state: .needsInput("Run the API test suite?"))
        waiting.agentStatus = "Ready to verify the API changes"
        waiting.pendingRequest = "pnpm test --filter api"
        // Handed to Sumi, so its card shows the Sumi tag.
        waiting.delegation = Delegation(scope: .turn, note: "prefer pnpm")
        terminalPixels(waiting, lines: [
            ("codex · api-contracts", .accent),
            ("", .normal),
            ("  Updated API response validation.", .normal),
            ("  Added coverage for empty responses.", .normal),
            ("", .normal),
            ("  Approval requested", .attention),
            ("  pnpm test --filter api", .normal),
            ("", .normal),
            ("  Waiting for your decision.", .muted),
        ])

        let review = sample("navigation", kind: .claude, branch: "feat/navigation", state: .idle)
        review.summary = "Navigation refresh ready for review"
        review.readyForReview = true
        review.finishedUnseen = true
        review.diffStat = DiffStat(added: 142, removed: 38, files: 5)
        review.testEvidence = TestEvidence(passed: true, summary: "42 checks passed", date: now)
        terminalPixels(review, lines: [
            ("claude · navigation", .accent),
            ("", .normal),
            ("  ✓ Navigation refresh complete", .success),
            ("", .normal),
            ("  5 files changed  ·  +142 −38", .normal),
            ("  42 checks passed", .success),
            ("", .normal),
            ("  Ready for your review.", .muted),
        ])

        var serverSpec = LaunchSpec(label: "atlas-web", kind: .server, cwd: "/workspace/atlas", command: "pnpm dev")
        serverSpec.port = 5173
        let server = TerminalSession(spec: serverSpec, resume: false)
        server.ports = [5173]
        server.git = GitInfo(project: "atlas", branch: "main", root: "/workspace/atlas", isWorktree: false, mainRoot: "/workspace/atlas")
        return [builder, waiting, review, server]
    }

    private func sample(_ label: String, kind: SessionKind, branch: String, state: AgentState) -> TerminalSession {
        var spec = LaunchSpec(label: label, kind: kind, cwd: "/workspace/atlas")
        spec.baseBranch = "main"
        let session = TerminalSession(spec: spec, resume: false)
        session.apply(.processStarted, source: "visual fixture", force: state)
        session.git = GitInfo(project: "atlas", branch: branch, root: "/workspace/atlas", isWorktree: true, mainRoot: "/workspace/atlas")
        return session
    }

    private enum TerminalTone { case normal, muted, accent, success, attention }

    /// Inert text stands in for terminal pixels while the native production tile stays intact.
    private func terminalPixels(_ session: TerminalSession, lines: [(String, TerminalTone)]) {
        let text = NSTextView()
        text.isEditable = false
        text.isSelectable = false
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 18, height: 18)
        text.translatesAutoresizingMaskIntoConstraints = false
        let content = NSMutableAttributedString(string: "")
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5
        for (line, tone) in lines {
            let color: NSColor
            switch tone {
            case .normal: color = Theme.terminalForeground
            case .muted: color = Ink.muted
            case .accent: color = Ink.accent
            case .success: color = NSColor(Palette.running)
            case .attention: color = NSColor(Palette.attention)
            }
            content.append(NSAttributedString(string: line + "\n", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ]))
        }
        text.textStorage?.setAttributedString(content)
        session.surface.addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: session.surface.leadingAnchor),
            text.trailingAnchor.constraint(equalTo: session.surface.trailingAnchor),
            text.topAnchor.constraint(equalTo: session.surface.topAnchor),
            text.bottomAnchor.constraint(equalTo: session.surface.bottomAnchor),
        ])
    }

    private func captureWorkspace(store: SessionStore, output: URL, name: String = "workspace",
                                  showInspector: Bool = true, captureNarrow: Bool = true) throws {
        // The production controller uses autosaved geometry. Restore only its geometry keys.
        let defaults = UserDefaults.standard
        let prior = defaults.dictionaryRepresentation().filter { geometryKey($0.key) }
        defer {
            for key in defaults.dictionaryRepresentation().keys where geometryKey(key) {
                if let value = prior[key] { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        let controller = MainWindowController(store: store)
        let window = try XCTUnwrap(controller.window)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 1440, height: 900))
        defer {
            (window.contentViewController as? NSSplitViewController)?.splitView.autosaveName = nil
            window.setFrameAutosaveName("")
            window.delegate = nil
            window.close()
        }
        for session in store.sessions { store.onSurfaceChange?(session) }
        store.onStatusChange?()
        settle(window.contentView)
        if showInspector {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                controller.toggleInspector()
            }
            settle(window.contentView)
        }
        let content = try XCTUnwrap(window.contentView)
        settle(content.superview)
        try validateWorkspaceLayout(controller)
        // The theme frame includes the real toolbar and titlebar in this view-based capture.
        try write(content.superview ?? content, name: name, output: output)

        if captureNarrow {
            if showInspector {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0
                    controller.toggleInspector()
                }
                settle(content)
            }
            window.setContentSize(NSSize(width: 780, height: 600))
            settle(content.superview)
            try validateWorkspaceLayout(controller)
            try write(content.superview ?? content, name: name + "-narrow", output: output)
        }
    }

    private func validateWorkspaceLayout(_ controller: MainWindowController) throws {
        let split = try XCTUnwrap(controller.window?.contentViewController as? NSSplitViewController)
        let bounds = split.splitView.bounds.insetBy(dx: -1, dy: -1)
        for item in split.splitViewItems where !item.isCollapsed {
            let frame = item.viewController.view.frame
            XCTAssertTrue(frame.width.isFinite && frame.height.isFinite)
            XCTAssertGreaterThan(frame.width, 0)
            XCTAssertGreaterThan(frame.height, 0)
            XCTAssertTrue(bounds.contains(frame), "Visible pane escapes the workspace: \(frame)")
        }
        for tile in descendants(of: TileView.self, in: split.view) where !tile.isHidden {
            let frame = tile.frame
            XCTAssertTrue(frame.width.isFinite && frame.height.isFinite)
            XCTAssertGreaterThanOrEqual(frame.width, 0)
            XCTAssertGreaterThanOrEqual(frame.height, 0)
            let parent = try XCTUnwrap(tile.superview)
            XCTAssertTrue(parent.bounds.insetBy(dx: -1, dy: -1).contains(frame),
                          "Visible terminal escapes its canvas: \(frame)")
        }
    }

    private func descendants<T: NSView>(of type: T.Type, in root: NSView) -> [T] {
        var matches: [T] = []
        for child in root.subviews {
            if let match = child as? T { matches.append(match) }
            matches.append(contentsOf: descendants(of: type, in: child))
        }
        return matches
    }

    private func geometryKey(_ key: String) -> Bool {
        key.contains("TakoMain") || key.contains("KuronamiWorkspace.v3")
    }

    private func capture<Content: View>(_ view: Content, size: NSSize, name: String, output: URL) throws {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Ink.deep
        window.contentView = host
        defer { window.close() }
        // Offscreen windows are never ordered front, made key, or activated.
        settle(host)
        try write(host, name: name, output: output)
    }

    private func settle(_ view: NSView?) {
        for _ in 0..<12 {
            view?.needsLayout = true
            view?.layoutSubtreeIfNeeded()
            view?.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.025))
        }
    }

    private func write(_ view: NSView, name: String, output: URL) throws {
        XCTAssertGreaterThan(view.bounds.width, 0, "\(name) has no width")
        XCTAssertGreaterThan(view.bounds.height, 0, "\(name) has no height")
        // Always 2x, whatever display the test runs on, so captures are sharp in the README.
        let image = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * 2),
                                                   pixelsHigh: Int(view.bounds.height * 2), bitsPerSample: 8,
                                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                                  "\(name) has no bitmap")
        image.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: image)
        XCTAssertGreaterThanOrEqual(image.pixelsWide, Int(view.bounds.width))
        XCTAssertGreaterThanOrEqual(image.pixelsHigh, Int(view.bounds.height))
        let png = try XCTUnwrap(image.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 1_000, "\(name) capture is unexpectedly empty")
        try png.write(to: output.appendingPathComponent(name + ".png"), options: .atomic)
    }
}
