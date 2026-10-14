import XCTest
@testable import Hyperterm

/// Phone Mode with Sumi as the control center: it hears every agent at once, by name, gets the
/// waits only the user can answer, and keeps reminding until a wait is answered. Preview stores
/// post no banners.
@MainActor
final class SumiControlCenterTests: XCTestCase {
    func testQuestionsAndPlansAreNeverAllowedUnseen() {
        let (store, api, _) = fixture()
        store.setPhoneMode(true)
        var answered: String?
        let question: [String: Any] = ["questions": [["question": "Which DB?", "options": [["label": "Postgres"], ["label": "SQLite"]]]]]
        store.registerApproval(for: api, source: "claude", payload: payload("AskUserQuestion", question)) { answered = $0.text }

        XCTAssertNil(answered, "a question waits for the user instead of being allowed unseen")
        XCTAssertTrue(api.hasHookApproval)
        XCTAssertEqual(api.pendingQuestion?.items.first?.options.map(\.label), ["Postgres", "SQLite"])

        let plan = SessionStore.asksTheUser
        XCTAssertTrue(plan.contains("ExitPlanMode"))
    }

    func testSumiHearsAQuestionWithNumberedOptionsAtOnce() {
        let (store, api, _) = fixture()
        store.setPhoneMode(true)
        let question: [String: Any] = ["questions": [["question": "Which DB?", "options": [["label": "Postgres"], ["label": "SQLite"]]]]]
        store.registerApproval(for: api, source: "claude", payload: payload("AskUserQuestion", question)) { _ in }
        guard case .needsInput(let reason) = api.state else { return XCTFail("not waiting") }
        XCTAssertTrue(store.sumiTakesWait(api, reason: reason))

        let line = store.sumiDigest.events.last?.line ?? ""
        XCTAssertTrue(line.hasPrefix("@api is waiting"), line)
        XCTAssertTrue(line.contains("1. Postgres; 2. SQLite"), line)
        XCTAssertTrue(line.contains("choose_option"), line)
        XCTAssertTrue(store.sumiDigest.isDue(at: Date().addingTimeInterval(SumiDigest.urgentWindow + 0.01)), "a wait goes out almost at once")
    }

    func testTrustAndSignInGoToSumiOnlyInPhoneMode() {
        let (store, api, _) = fixture()
        _ = store.delegate(api, scope: .turn, note: nil)
        api.apply(.processStarted, source: "trust prompt", force: .needsInput(TerminalSession.trustReason))
        XCTAssertFalse(store.sumiTakesWait(api, reason: TerminalSession.trustReason), "at the Mac, trusting is the user's own")

        store.setPhoneMode(true)
        XCTAssertTrue(store.sumiTakesWait(api, reason: TerminalSession.trustReason))
        XCTAssertTrue(store.sumiDigest.events.last?.line.contains("trust_folder") == true)

        api.apply(.processStarted, source: "trust prompt", force: .needsInput("Sign in to Codex"))
        XCTAssertTrue(store.sumiTakesWait(api, reason: "Sign in to Codex"))
        XCTAssertTrue(store.sumiDigest.events.last?.line.contains("sign_in") == true)
    }

    func testTrustNeedsTheUsersYes() {
        let (store, api, _) = fixture()
        api.apply(.processStarted, source: "trust prompt", force: .needsInput(TerminalSession.trustReason))
        guard case .failure(let notHanded) = store.trustForSumi(api, userApproved: true) else { return XCTFail() }
        XCTAssertTrue(notHanded.description.contains("isn't handed to you"))

        store.setPhoneMode(true)
        guard case .failure(let ask) = store.trustForSumi(api, userApproved: false) else { return XCTFail() }
        XCTAssertTrue(ask.description.contains("ask the user"))
    }

    func testChooseOptionChecksTheQuestion() {
        let (store, api, _) = fixture()
        store.setPhoneMode(true)
        var refused: String?
        store.chooseForSumi(api, options: [1]) { if case .failure(let error) = $0 { refused = error.description } }
        XCTAssertTrue(refused?.contains("no numbered menu on screen") == true)

        api.pendingQuestion = PendingQuestion.parse(toolInput: ["questions": [["question": "Q", "options": [["label": "A"], ["label": "B"]]]]])
        api.apply(.processStarted, source: "test", force: .needsInput("Q"))
        store.chooseForSumi(api, options: [3]) { if case .failure(let error) = $0 { refused = error.description } }
        XCTAssertEqual(refused, "option must be 1–2")
    }

    func testSumisHandsNeedPhoneModeOrAHandoff() {
        let (store, api, sumi) = fixture()
        var refused: [String] = []
        let collect: (Result<String, DelegationError>) -> Void = { if case .failure(let error) = $0 { refused.append(error.description) } }
        store.interruptForSumi(api, hard: false, completion: collect)
        store.pressKeysForSumi(api, keys: ["enter"], userApproved: false, completion: collect)
        store.typeForSumi(api, text: "hi", submit: true, completion: collect)
        store.setModeForSumi(api, mode: .plan, completion: collect)
        XCTAssertEqual(refused.count, 4)
        XCTAssertTrue(refused.allSatisfy { $0.contains("isn't handed to you") })
        guard case .failure = store.restartForSumi(api) else { return XCTFail("not handed over") }
        store.interruptForSumi(sumi, hard: false, completion: collect)
        XCTAssertTrue(refused.last?.contains("isn't an agent") == true, "Sumi doesn't interrupt itself")

        store.setPhoneMode(true)
        refused = []
        store.pressKeysForSumi(api, keys: ["enter", "hyper-x"], userApproved: false, completion: collect)
        XCTAssertTrue(refused.first?.contains("unknown key names: hyper-x") == true)
        store.typeForSumi(api, text: "!rm -rf ~", submit: true, completion: collect)
        XCTAssertTrue(refused.last?.contains("shell command") == true)
        store.setModeForSumi(api, mode: .fullAccess, completion: collect)
        XCTAssertTrue(refused.last?.contains("never asks again") == true)
    }

    func testDigestDropsRepeatsAndCaps() {
        var digest = SumiDigest()
        digest.add(SumiEvent(label: "api", kind: .stoppedHandling("x")))
        digest.add(SumiEvent(label: "api", kind: .stoppedHandling("x")))
        XCTAssertEqual(digest.events.count, 1)
        for index in 0..<(SumiDigest.cap + 5) { digest.add(SumiEvent(label: "a\(index)", kind: .stoppedHandling("x"))) }
        XCTAssertEqual(digest.events.count, SumiDigest.cap)
        XCTAssertTrue(digest.take()?.contains("6 older updates left out") == true)
    }

    func testTakoAgentsDropDuplicateBrowserPlugins() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("plugins-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = #"{"enabledPlugins": {"chrome-devtools-mcp@claude-plugins-official": true, "playwright@x": false, "stripe@claude-plugins-official": true}}"#
        try Data(settings.utf8).write(to: home.appendingPathComponent(".claude/settings.json"))
        XCTAssertEqual(ClaudeAdapter.duplicateBrowserPlugins(home: home), ["chrome-devtools-mcp@claude-plugins-official"])
    }

    func testAlwaysNeedsPhoneModeAndTheUsersYes() {
        let (store, api, _) = fixture()
        _ = store.delegate(api, scope: .turn, note: nil)
        guard case .failure(let atMac) = store.answerForSumi(api, .always, reason: nil, userApproved: true) else { return XCTFail() }
        XCTAssertTrue(atMac.description.contains("needs the user's yes"))
        store.setPhoneMode(true)
        guard case .failure(let unasked) = store.answerForSumi(api, .always, reason: nil) else { return XCTFail() }
        XCTAssertTrue(unasked.description.contains("needs the user's yes"))
    }

    func testInPhoneModeSumiHearsEveryAgentFinishWithoutAWatch() {
        let (store, api, _) = fixture()
        api.apply(.processStarted, source: "test", force: .working)
        api.apply(.processStarted, source: "test", force: .idle)
        store.reportToSumi(api, from: .working)
        XCTAssertTrue(store.sumiDigest.isEmpty, "at the Mac, only watched agents are reported")

        store.setPhoneMode(true)
        store.sumiDigest = SumiDigest()
        api.apply(.processStarted, source: "test", force: .working)
        api.apply(.processStarted, source: "test", force: .idle)
        store.reportToSumi(api, from: .working)
        XCTAssertTrue(store.sumiDigest.events.last?.line.hasPrefix("@api finished") == true)
    }

    func testAnUnansweredWaitRemindsSumiToPushThePhone() {
        let (store, api, _) = fixture()
        store.setPhoneMode(true)
        api.apply(.processStarted, source: "test", force: .needsInput("Bash: pnpm deploy"))
        XCTAssertTrue(store.sumiTakesWait(api, reason: "Bash: pnpm deploy"))

        var now = Date().addingTimeInterval(Delegation.fallback + 1)
        store.sweepDelegations(now: now)
        XCTAssertEqual(api.delegation?.reminders, 1)
        guard case .stillWaiting(_, let seconds) = store.sumiDigest.events.last?.kind else { return XCTFail("no reminder") }
        XCTAssertEqual(seconds, Int(Delegation.fallback))
        XCTAssertTrue(store.sumiDigest.events.last?.line.contains("Push the user a notification") == true)

        for _ in 1..<Delegation.phoneReminders {
            now = now.addingTimeInterval(Delegation.fallback + 1)
            store.sweepDelegations(now: now)
        }
        XCTAssertEqual(api.delegation?.reminders, Delegation.phoneReminders)
        now = now.addingTimeInterval(Delegation.fallback + 1)
        store.sweepDelegations(now: now)
        XCTAssertEqual(api.delegation?.reminders, 0, "after the reminders it goes to the Mac, and counts as handled")
        XCTAssertEqual(api.delegation?.handled, 1)
    }

    func testAnsweringEndsTheReminders() {
        let (store, api, _) = fixture()
        store.setPhoneMode(true)
        api.apply(.processStarted, source: "test", force: .needsInput("Bash: pnpm deploy"))
        XCTAssertTrue(store.sumiTakesWait(api, reason: "Bash: pnpm deploy"))
        store.sweepDelegations(now: Date().addingTimeInterval(Delegation.fallback + 1))

        let previous = api.state
        api.apply(.processStarted, source: "test", force: .working)
        store.delegationStateChanged(api, from: previous)
        XCTAssertNil(api.delegation?.toldAt)
        XCTAssertEqual(api.delegation?.reminders, 0)
    }

    func testDigestWindows() {
        var digest = SumiDigest()
        let start = Date()
        digest.add(SumiEvent(label: "api", kind: .finished("done")), at: start)
        XCTAssertFalse(digest.isDue(at: start.addingTimeInterval(SumiDigest.urgentWindow)))
        XCTAssertTrue(digest.isDue(at: start.addingTimeInterval(SumiDigest.window + 0.01)))
        digest.add(SumiEvent(label: "web", kind: .needsYou("Bash: ls", note: nil)), urgent: true, at: start)
        XCTAssertTrue(digest.isDue(at: start.addingTimeInterval(SumiDigest.urgentWindow + 0.01)))
        _ = digest.take()
        digest.add(SumiEvent(label: "api", kind: .finished("done")), at: start)
        XCTAssertFalse(digest.isDue(at: start.addingTimeInterval(SumiDigest.urgentWindow)), "urgency ends with the message it was in")
    }

    // MARK: - Codex menus

    /// Codex 0.160's folder prompt, as read from a live session.
    private let codexTrust = """
      Trust this folder? Codex can read, edit, and run files here, subject to your permission settings.

    › 1. Trust and continue
      2. Quit

      enter continue · esc quit
    """

    func testCodexTrustIsAnsweredWithEnterOnTrustAndContinue() {
        XCTAssertEqual(PromptScreen.keys(for: .approve, screen: codexTrust, kind: .codex), ["enter"],
                       "a digit alone does nothing in Codex; Enter confirms the highlighted option")
        XCTAssertEqual(PromptScreen.keys(for: .deny, screen: codexTrust, kind: .codex), ["esc"],
                       "deny never presses Enter on whatever is highlighted")
    }

    func testCodexOptionsAreReachedWithArrowsFromTheHighlight() {
        let approval = """
          Allow command?
          1. Yes, proceed
        › 2. Yes, and don't ask again for this command
          3. No, and tell Codex what to do differently
        """
        XCTAssertEqual(PromptScreen.highlighted(approval), 2)
        XCTAssertEqual(PromptScreen.keys(for: .approve, screen: approval, kind: .codex), ["up", "enter"])
        XCTAssertEqual(PromptScreen.keys(for: .deny, screen: approval, kind: .codex), ["down", "enter"])
        XCTAssertEqual(PromptScreen.keys(toOption: 3, screen: approval, kind: .claude), ["3"], "Claude acts on the digit")
    }

    func testPhoneModeReportsSumiUnfocusedSoPushesReachThePhone() {
        let (store, _, sumi) = fixture()
        store.setPhoneMode(true)
        XCTAssertEqual((sumi.surface as? TerminalSurfaceView)?.reportsUnfocused, true)
        store.setPhoneMode(false)
        XCTAssertEqual((sumi.surface as? TerminalSurfaceView)?.reportsUnfocused, false)
    }

    // MARK: - Fixtures

    private func fixture() -> (SessionStore, TerminalSession, TerminalSession) {
        let api = agent("api"), sumi = agent("sumi", sumi: true)
        sumi.apply(.processStarted, source: "test", force: .working)
        let store = SessionStore(previewSessions: [api, sumi], previewLayout: .grid)
        api.store = store
        return (store, api, sumi)
    }

    private func agent(_ label: String, sumi: Bool = false) -> TerminalSession {
        var spec = LaunchSpec(label: label, kind: .claude, cwd: "/workspace/atlas")
        if sumi { spec.sumi = true }
        let session = TerminalSession(spec: spec, resume: false)
        session.apply(.processStarted, source: "test", force: .idle)
        return session
    }

    private func payload(_ tool: String, _ input: [String: Any]) -> String {
        let payload: [String: Any] = ["tool_name": tool, "tool_input": input, "cwd": "/workspace/atlas"]
        return String(decoding: try! JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
    }
}
