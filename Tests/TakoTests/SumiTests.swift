import XCTest
@testable import Tako

/// Sumi behind the sidebar's box. Only paths that write nothing to disk or defaults:
/// the test host shares the app's.
@MainActor
final class SumiTests: XCTestCase {
    func testButtonEmphasizesWhenSumiNeedsYouOrHasAnUnseenReply() {
        let mood = KuronamiMark.sumiMood
        XCTAssertEqual(mood(.idle, false, false), .resting)
        XCTAssertEqual(mood(.working, true, false), .working, "working animates the mark even with an old unread reply")
        XCTAssertEqual(mood(.needsInput("ok?"), false, true), .needsYou, "blocked on you shows even with the panel open")
        XCTAssertEqual(mood(.idle, true, false), .needsYou, "a reply nobody has opened")
        XCTAssertEqual(mood(.idle, true, true), .resting, "the panel is open, so the reply is being read")
    }

    func testSumiKeepsItsOldNameOnDiskAndOnTheWire() throws {
        // A sessions.json written before the rename still marks the session as Sumi.
        let saved = try JSONEncoder().encode(LaunchSpec(label: "sumi", kind: .claude, cwd: "/tmp"))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        json["organizer"] = true
        let old = try JSONSerialization.data(withJSONObject: json)
        let spec = try JSONDecoder().decode(LaunchSpec.self, from: old)
        XCTAssertEqual(spec.sumi, true)
        let again = try XCTUnwrap(JSONSerialization.jsonObject(with: try JSONEncoder().encode(spec)) as? [String: Any])
        XCTAssertEqual(again["organizer"] as? Bool, true)
        XCTAssertNil(again["sumi"])

        // Same for the session info an `ht` from before the rename reads.
        let info = try JSONEncoder().encode(agent("sumi", sumi: true).info())
        let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: info) as? [String: Any])
        XCTAssertEqual(wire["organizer"] as? Bool, true)
    }

    func testSumiTakesNoTileAndNoCard() {
        let api = agent("api"), web = agent("web"), sumi = agent("sumi", sumi: true)
        let store = SessionStore(previewSessions: [api, sumi, web], previewLayout: .grid)

        XCTAssertTrue(store.sumi === sumi)
        XCTAssertFalse(store.visibleIDs.contains(sumi.id))
        XCTAssertEqual(Set(store.visibleIDs), [api.id, web.id])
        XCTAssertFalse(store.projects.flatMap(\.agents).contains { $0 === sumi })
        XCTAssertEqual(sumi.info().sumi, true)
        XCTAssertNil(api.info().sumi)
    }

    func testSumisBrowsersAreListedWithTheLooseOnes() {
        let api = agent("api"), sumi = agent("sumi", sumi: true)
        func browser(_ label: String, owner: TerminalSession?) -> TerminalSession {
            var spec = LaunchSpec(label: label, kind: .browser, cwd: "/workspace/atlas")
            spec.owner = owner?.id
            return TerminalSession(spec: spec, resume: false)
        }
        let mine = browser("docs", owner: api), its = browser("alpha", owner: sumi), loose = browser("web", owner: nil)
        let store = SessionStore(previewSessions: [api, sumi, mine, its, loose], previewLayout: .grid)

        XCTAssertEqual(store.browsers(ownedBy: api).map(\.id), [mine.id])
        XCTAssertEqual(store.looseBrowsers.map(\.id), [its.id, loose.id])
    }

    func testChoosingTheSumiOpensItsPanelInsteadOfATile() {
        let api = agent("api"), sumi = agent("sumi", sumi: true)
        let store = SessionStore(previewSessions: [api, sumi], previewLayout: .focus)
        store.select(api)
        var opened = 0
        store.onShowSumi = { opened += 1 }

        store.select(sumi)

        XCTAssertEqual(opened, 1)
        XCTAssertEqual(store.selectedID, api.id)
        XCTAssertEqual(store.visibleIDs, [api.id])
    }

    func testWatchedAgentFinishingTellsTheSumiOnce() {
        let api = agent("api", state: .idle), sumi = agent("sumi", sumi: true, state: .needsInput("busy"))
        let store = SessionStore(previewSessions: [api, sumi], previewLayout: .grid)
        api.summary = "Added /orders.\nTests pass."
        store.sumiWatches[api.id] = "tell @web the endpoint is ready"

        store.reportToSumi(api, from: .working)
        store.reportToSumi(api, from: .working)
        store.flushSumiDigest(now: Date().addingTimeInterval(SumiDigest.window))

        // Queued because Sumi is at a prompt; one line, so it can't submit early.
        XCTAssertEqual(sumi.pendingMessages.count, 1)
        let report = sumi.pendingMessages.first ?? ""
        XCTAssertTrue(report.contains("@api finished: Added /orders. Tests pass."), report)
        XCTAssertTrue(report.contains("tell @web the endpoint is ready"), report)
        XCTAssertFalse(report.contains("\n"))
        XCTAssertNil(store.sumiWatches[api.id])
    }

    func testWatchWaitsThroughStatesThatAreNotAFinish() {
        let api = agent("api", state: .working), sumi = agent("sumi", sumi: true, state: .needsInput("busy"))
        let store = SessionStore(previewSessions: [api, sumi], previewLayout: .grid)
        store.sumiWatches[api.id] = "next"

        store.reportToSumi(api, from: .idle)

        XCTAssertTrue(sumi.pendingMessages.isEmpty)
        XCTAssertEqual(store.sumiWatches[api.id], "next")
    }

    func testWatchKeepsWhileTheSumiHasExited() {
        let api = agent("api", state: .idle), sumi = agent("sumi", sumi: true)
        let store = SessionStore(previewSessions: [api, sumi], previewLayout: .grid)
        sumi.apply(.childExited(0), source: "test")
        store.sumiWatches[api.id] = "next"

        store.reportToSumi(api, from: .working)

        XCTAssertTrue(store.sumiDigest.isEmpty)
        XCTAssertEqual(store.sumiWatches[api.id], "next")
    }

    func testAFinishedTurnIsMarkedDoneUntilLookedAtOrWorkResumes() {
        let api = agent("api", state: .working), web = agent("web", state: .idle)
        let store = SessionStore(previewSessions: [api, web], previewLayout: .grid)
        store.select(web)

        api.apply(.childExited(0), source: "test", force: .idle)
        store.sessionStateChanged(api, from: .working)
        XCTAssertTrue(api.finishedUnseen)
        XCTAssertFalse(web.finishedUnseen)

        store.select(api)
        XCTAssertFalse(api.finishedUnseen, "looking at it clears the mark")

        store.markFinished(web)
        XCTAssertTrue(web.finishedUnseen)
        web.apply(.childExited(0), source: "test", force: .working)
        XCTAssertFalse(web.finishedUnseen, "a new turn is not done")

        web.apply(.childExited(0), source: "test", force: .idle)
        web.runningSubagents = ["a1": Subagent(type: "Explore", startedAt: Date())]
        store.markFinished(web)
        XCTAssertFalse(web.finishedUnseen, "not done while a subagent still runs")
    }

    func testASelectedAgentIsMarkedDoneWhenOtherTerminalsAreOnScreen() {
        let api = agent("api", state: .idle), web = agent("web", state: .idle)
        let store = SessionStore(previewSessions: [api, web], previewLayout: .grid)
        store.select(web)

        store.markFinished(web)

        XCTAssertTrue(web.finishedUnseen, "two tiles are showing, so finishing is still worth marking")
    }

    func testMessagingAnAgentWatchesItForTheSumi() {
        let api = agent("api"), sumi = agent("sumi", sumi: true)
        let store = SessionStore(previewSessions: [api, sumi], previewLayout: .grid)
        var request = ControlRequest(cmd: .send)
        request.target = "api"
        request.text = "check the orders endpoint"

        ControlHandler(store: store, caller: .session(sumi.id.uuidString)).handle(request) { _ in }
        XCTAssertEqual(store.sumiWatches[api.id], "", "the reply will be reported")

        store.sumiWatches[api.id] = "then tell @web"
        ControlHandler(store: store, caller: .session(sumi.id.uuidString)).handle(request) { _ in }
        XCTAssertEqual(store.sumiWatches[api.id], "then tell @web", "an earlier note is kept")
    }

    func testBackgroundSubagentsHoldTheFinishUntilTheLastOneStops() {
        let api = agent("api", state: .idle), sumi = agent("sumi", sumi: true, state: .needsInput("busy"))
        let store = SessionStore(previewSessions: [api, sumi], previewLayout: .grid)
        store.sumiWatches[api.id] = "next"
        func hook(_ event: String, _ id: String) {
            store.applyHook(source: "claude", session: api, json: ["hook_event_name": event, "agent_id": id, "agent_type": "Explore"], sentAt: nil)
        }
        hook("SubagentStart", "a1")
        hook("SubagentStart", "a2")

        // The session's own turn ends while both still run.
        store.reportToSumi(api, from: .working)
        XCTAssertEqual(api.info().subagents, 2)
        XCTAssertEqual(api.runningSubagents["a1"]?.type, "Explore", "the sidebar names each one")
        hook("SubagentStop", "a1")
        hook("SubagentStop", "a1")
        store.flushSumiDigest(now: Date().addingTimeInterval(SumiDigest.window))
        XCTAssertTrue(sumi.pendingMessages.isEmpty)
        XCTAssertEqual(store.sumiWatches[api.id], "next")

        hook("SubagentStop", "a2")
        store.flushSumiDigest(now: Date().addingTimeInterval(SumiDigest.window))
        XCTAssertTrue((sumi.pendingMessages.first ?? "").contains("@api finished"), "\(sumi.pendingMessages)")
        XCTAssertNil(store.sumiWatches[api.id])
        XCTAssertNil(api.info().subagents)
    }

    func testEventsWaitForTheWindowAndArriveAsOneDigest() {
        let api = agent("api", state: .idle), db = agent("db", state: .failed("API error"))
        let sumi = agent("sumi", sumi: true, state: .needsInput("busy"))
        let store = SessionStore(previewSessions: [api, db, sumi], previewLayout: .grid)
        api.summary = "Added /orders."
        store.sumiWatches[api.id] = "tell @web"
        store.sumiWatches[db.id] = ""
        let start = Date()

        store.reportToSumi(api, from: .working)
        store.reportToSumi(db, from: .working)
        store.flushSumiDigest(now: start.addingTimeInterval(1))
        XCTAssertTrue(sumi.pendingMessages.isEmpty)

        store.flushSumiDigest(now: start.addingTimeInterval(SumiDigest.window + 1))
        XCTAssertEqual(sumi.pendingMessages,
                       ["Tako: 2 updates: [1] @api finished: Added /orders. (your note: tell @web) [2] @db failed: API error"])
        XCTAssertTrue(store.sumiDigest.isEmpty)
    }

    func testDigestReachesTheSumiEvenMidTurn() {
        let api = agent("api", state: .exited(0)), sumi = agent("sumi", sumi: true, state: .working)
        let store = SessionStore(previewSessions: [api, sumi], previewLayout: .grid)
        store.sumiWatches[api.id] = "restart it"

        store.reportToSumi(api, from: .working)
        store.flushSumiDigest(now: Date().addingTimeInterval(SumiDigest.window + 1))

        XCTAssertTrue(store.sumiDigest.isEmpty, "sent while it works: its CLI queues the message for the next step")
    }

    func testDigestWaitsWhileTheSumiIsStarting() {
        let api = agent("api", state: .exited(0)), sumi = agent("sumi", sumi: true, state: .starting)
        let store = SessionStore(previewSessions: [api, sumi], previewLayout: .grid)
        store.sumiWatches[api.id] = "restart it"

        store.reportToSumi(api, from: .working)
        store.flushSumiDigest(now: Date().addingTimeInterval(SumiDigest.window + 1))
        XCTAssertEqual(store.sumiDigest.events, [SumiEvent(label: "api", kind: .exited, note: "restart it")])
    }

    func testAHeldBackDigestIsTriedAgainWithoutWaitingForSumisNextChange() {
        let api = agent("api", state: .exited(0)), sumi = agent("sumi", sumi: true, state: .starting)
        let store = SessionStore(previewSessions: [api, sumi], previewLayout: .grid)
        store.sumiWatches[api.id] = "restart it"

        store.reportToSumi(api, from: .working)
        store.flushSumiDigest(now: Date().addingTimeInterval(SumiDigest.window + 1))
        XCTAssertFalse(store.sumiDigest.isEmpty)
        sumi.apply(.processStarted, source: "test", force: .working)
        RunLoop.main.run(until: Date().addingTimeInterval(SumiDigest.window + SumiDigest.retryInterval + 0.5))
        XCTAssertTrue(store.sumiDigest.isEmpty, "sent on the retry, though Sumi's state changed without a report")
    }

    func testDigestWindowStartsAtTheFirstEvent() {
        var digest = SumiDigest()
        let start = Date(timeIntervalSince1970: 1000)
        XCTAssertFalse(digest.isDue(at: start))
        digest.add(SumiEvent(label: "api", kind: .exited), at: start)
        digest.add(SumiEvent(label: "web", kind: .exited), at: start.addingTimeInterval(SumiDigest.window / 2))
        XCTAssertFalse(digest.isDue(at: start.addingTimeInterval(SumiDigest.window / 2)))
        XCTAssertTrue(digest.isDue(at: start.addingTimeInterval(SumiDigest.window)))

        let message = digest.take(cleared: true) ?? ""
        XCTAssertTrue(message.hasPrefix("Tako: Context was cleared: call standup, plan and recall"), message)
        XCTAssertTrue(message.contains(ControlPaths.sumiNotes), message)
        XCTAssertTrue(message.hasSuffix("[1] @api exited [2] @web exited"), message)
        XCTAssertNil(digest.take())
    }

    func testTileSpecsDecodeFromTheWire() throws {
        let json = #"{"split":"row","sizes":[2,1],"children":[{"terminal":"api"},{"split":"column","children":[{"terminal":"web"},{"terminal":"fix"}]}]}"#
        let spec = try JSONDecoder().decode(TileSpec.self, from: Data(json.utf8))
        XCTAssertEqual(spec.split, "row")
        XCTAssertEqual(spec.sizes, [2, 1])
        XCTAssertEqual(spec.children?.first?.terminal, "api")
        XCTAssertEqual(spec.children?.last?.children?.map(\.terminal), ["web", "fix"])
    }

    func testHistoryDescribesEachClosedSessionOnItsOwnLines() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var api = LaunchSpec(label: "api", kind: .claude, cwd: "/workspace/atlas")
        api.createdAt = now.addingTimeInterval(-3 * 3600)
        api.agentSessionId = "abc"
        api.worktreeBranch = "kuronami/api"
        api.summary = "Added /orders.\nTests pass."
        api.memory = SessionMemory(task: "Add an orders endpoint", closedAt: now.addingTimeInterval(-600),
                                   finalState: "Idle", events: ["Ran tests", "Committed"])
        var web = LaunchSpec(label: "web", kind: .codex, cwd: "/workspace/shop")
        web.createdAt = now.addingTimeInterval(-60)

        let lines = SessionStore.describeHistory([api, web], now: now).components(separatedBy: "\n")

        XCTAssertEqual(lines, [
            "@api [claude] /workspace/atlas (branch kuronami/api) · started 3 hours ago, closed 10 minutes ago · resumes its conversation",
            "    ended: Idle",
            "    summary: Added /orders. Tests pass.",
            "    task: Add an orders endpoint",
            "    - Ran tests",
            "    - Committed",
            "@web [codex] /workspace/shop · started 1 minute ago · starts fresh",
        ])
    }

    func testHistoryFiltersByFolderAndLeavesOutPastSumis() {
        let store = SessionStore(previewSessions: [], previewLayout: .grid)
        var sumi = LaunchSpec(label: "sumi", kind: .claude, cwd: "/workspace/atlas")
        sumi.sumi = true
        var renamed = LaunchSpec(label: "api", kind: .claude, cwd: "/workspace/atlas/server")
        renamed.previousLabels = ["bravo"]
        let other = LaunchSpec(label: "web", kind: .claude, cwd: "/workspace/atlas-web")
        store.recentlyClosed = [sumi, renamed, other]

        XCTAssertEqual(store.closedSessions().map(\.label), ["api", "web"])
        XCTAssertEqual(store.closedSessions(in: "/workspace/atlas/").map(\.label), ["api"])
        XCTAssertEqual(store.closedSession(named: "@Bravo")?.id, renamed.id)
        XCTAssertEqual(store.closedSession(named: other.id.uuidString)?.id, other.id)
        XCTAssertNil(store.closedSession(named: "sumi"))
    }

    // MARK: - Choosing its CLI

    /// Runs `body` with Sumi's choice kept in a throwaway suite, not the app's defaults.
    private func withOwnDefaults(_ body: (UserDefaults) -> Void) {
        let name = "SumiTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let saved = SessionStore.sumiDefaults
        SessionStore.sumiDefaults = defaults
        defer { SessionStore.sumiDefaults = saved; defaults.removePersistentDomain(forName: name) }
        body(defaults)
    }

    func testSumiStartsAtOnceOnItsCLIsDefaultModel() {
        withOwnDefaults { _ in
            let store = SessionStore(previewSessions: [], previewLayout: .grid)
            XCTAssertNil(SessionStore.chosenSumiKind)
            XCTAssertFalse(store.sumiNeedsChoice, "no chooser: Sumi starts when its panel opens")
            for kind in SessionStore.sumiChoices {
                XCTAssertNil(SessionStore.sumiModel(for: kind), "\(kind) launches with no model flag: the CLI's default")
            }
            SessionStore.setSumiModel("sonnet", for: .claude)
            XCTAssertEqual(SessionStore.sumiModel(for: .claude), "sonnet", "a model the user picked still sticks")
        }
    }

    func testAModelSavedForAnotherCLIIsNeverLaunched() {
        withOwnDefaults { _ in
            // Codex's model saved under Claude, as an earlier mix-up left it.
            SessionStore.sumiDefaults.set("gpt-6-luna", forKey: "organizerModel.claude")
            XCTAssertNil(SessionStore.chosenSumiModel(for: .claude), "it is dropped, so Sumi uses the default")
            XCTAssertNil(SessionStore.sumiModel(for: .claude), "and Claude is launched with no model flag")
            XCTAssertNil(SessionStore.sumiDefaults.string(forKey: "organizerModel.claude"), "the bad value is cleaned up")

            XCTAssertTrue(SessionStore.isSumiModel("haiku", of: .claude))
            XCTAssertFalse(SessionStore.isSumiModel("haiku", of: .codex))
            XCTAssertTrue(SessionStore.isSumiModel("", of: .codex), "the CLI's own default fits every CLI")
        }
    }

    func testTheModelStepSavesForTheCLIItShowedNotTheCurrentOne() {
        withOwnDefaults { _ in
            let store = SessionStore(previewSessions: [], previewLayout: .grid)
            SessionStore.sumiKind = .claude
            store.chooseSumiModel("gpt-6-luna", for: .codex)
            XCTAssertEqual(SessionStore.sumiKind, .codex, "the CLI whose models were shown is the one chosen")
            XCTAssertEqual(SessionStore.chosenSumiModel(for: .codex), "gpt-6-luna")
            XCTAssertNil(SessionStore.chosenSumiModel(for: .claude), "nothing lands under the other CLI")

            store.chooseSumiModel("haiku", for: .codex)
            XCTAssertEqual(SessionStore.chosenSumiModel(for: .codex), "gpt-6-luna", "a model of another CLI is refused")
        }
    }

    func testAModelPickedMidSwitchKeepsTheChosenCLI() {
        withOwnDefaults { _ in
            // Codex is still running (or launching) while Claude is already the choice.
            let store = SessionStore(previewSessions: [agent("sumi", sumi: true, kind: .codex)], previewLayout: .grid)
            SessionStore.sumiKind = .claude
            SessionStore.setSumiModel("haiku", for: .claude)

            // The menu lists the chosen CLI's models, so picking one never writes the running CLI back.
            store.chooseSumiModel("sonnet", for: SessionStore.sumiKind)
            XCTAssertEqual(SessionStore.sumiKind, .claude)
            XCTAssertEqual(SessionStore.chosenSumiModel(for: .claude), "sonnet")
        }
    }

    func testEachCLIListsItsOwnDefaultFirst() {
        for kind in SessionStore.sumiChoices {
            let models = SessionStore.sumiModels(for: kind)
            XCTAssertNil(models.first?.name, "\(kind)'s own default comes first")
            XCTAssertTrue(models.dropFirst().allSatisfy { $0.name.flatMap(AgentOptions.validModel) != nil }, "\(kind)")
        }
    }

    func testAnSumiRunningFromBeforeNeedsNoChoice() {
        withOwnDefaults { _ in
            let store = SessionStore(previewSessions: [agent("sumi", sumi: true)], previewLayout: .grid)
            XCTAssertNil(SessionStore.chosenSumiKind)
            XCTAssertFalse(store.sumiNeedsChoice)
        }
    }

    func testChoosingPersists() {
        withOwnDefaults { defaults in
            SessionStore.sumiKind = .codex
            XCTAssertEqual(defaults.string(forKey: SessionStore.sumiKindKey), "codex")
            XCTAssertEqual(SessionStore.chosenSumiKind, .codex)
            // Something that can't run it reads as not chosen.
            defaults.set("shell", forKey: SessionStore.sumiKindKey)
            XCTAssertNil(SessionStore.chosenSumiKind)
        }
    }

    func testSumiChoicesAreTheAgentKinds() {
        XCTAssertEqual(SessionStore.sumiChoices, SessionKind.allCases.filter(\.isAgent))
        XCTAssertTrue(SessionStore.sumiChoices.contains(.claude))
        XCTAssertFalse(SessionStore.sumiChoices.contains(.shell))
    }

    func testInstalledCLIsComeFromThePATHWithoutKuronamisWrappers() {
        let executables: Set<String> = ["/Users/me/.hyperterm/bin/claude", "/Users/me/.hyperterm/bin/codex", "/opt/homebrew/bin/codex"]
        let installed = InstalledAgents.installed([.claude, .codex], path: "/Users/me/.hyperterm/bin/:/usr/bin:/opt/homebrew/bin",
                                                  skipping: "/Users/me/.hyperterm/bin", isExecutable: executables.contains)
        XCTAssertEqual(installed, [.codex])
        XCTAssertEqual(InstalledAgents.installed([.claude, .codex], path: "", skipping: "/x", isExecutable: { _ in true }), [])
    }

    private func agent(_ label: String, sumi: Bool = false, kind: SessionKind = .claude, state: AgentState = .idle) -> TerminalSession {
        var spec = LaunchSpec(label: label, kind: kind, cwd: "/workspace/atlas")
        if sumi { spec.sumi = true }
        let session = TerminalSession(spec: spec, resume: false)
        session.apply(.processStarted, source: "test", force: state)
        return session
    }
}
