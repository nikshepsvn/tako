import XCTest
@testable import Tako

/// Phone Mode: every agent's waits go to Sumi, ordinary requests are allowed by the app,
/// and risky ones need the user's yes from their phone. Preview stores post no banners.
@MainActor
final class PhoneModeTests: XCTestCase {
    /// Sumi's CLI and model are kept in a throwaway suite: the test host shares the dev app's
    /// preferences, and switching Sumi here must never switch the user's.
    private var savedDefaults: UserDefaults!
    private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "PhoneModeTests-\(UUID().uuidString)"
        savedDefaults = SessionStore.sumiDefaults
        SessionStore.sumiDefaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        SessionStore.sumiDefaults.removePersistentDomain(forName: suiteName)
        SessionStore.sumiDefaults = savedDefaults
        super.tearDown()
    }

    func testTurningOnHandsEveryAgentToTheSumiAndOffHandsThemBack() {
        let (store, api, sumi) = fixture(extra: "web")
        let web = store.sessions.first { $0.label == "web" }!
        _ = store.delegate(web, scope: .count(3), note: "prefer pnpm")

        store.setPhoneMode(true)
        XCTAssertEqual(api.delegation?.scope, .phoneMode)
        XCTAssertEqual(api.delegation?.shortScope, "phone")
        XCTAssertEqual(web.delegation?.scope, .count(3), "a scope the user chose stays")
        XCTAssertNil(sumi.delegation)
        XCTAssertEqual(store.sumiDigest.events.first?.kind, .phoneMode(true))

        store.setPhoneMode(false)
        XCTAssertNil(api.delegation)
        XCTAssertEqual(web.delegation?.scope, .count(3))
        XCTAssertNil(store.phoneModeSince)
        XCTAssertEqual(store.sumiDigest.events.last?.kind, .phoneMode(false))
    }

    func testStartingWithTheSumiUpOpensRemoteControlAtOnce() {
        let (store, _, sumi) = fixture()
        store.startPhoneMode()
        XCTAssertTrue(store.isPhoneModeOn)
        XCTAssertFalse(store.remoteControlWhenSumiUp)
        XCTAssertEqual(sumi.pendingMessages.last, "/remote-control")
    }

    func testPhoneModeScopeNeverRunsOut() {
        var delegation = Delegation(scope: .phoneMode)
        delegation.handled = 500
        XCTAssertFalse(delegation.isUsedUp(at: .distantFuture))
        XCTAssertEqual(delegation.scopePhrase, "while Phone Mode is on")
    }

    func testAgentsStartedWhileOnAreAdopted() {
        let (store, _, _) = fixture()
        store.setPhoneMode(true)
        let late = agent("late")
        XCTAssertTrue(store.adoptIntoPhoneMode(late))
        XCTAssertEqual(late.delegation?.scope, .phoneMode)
        XCTAssertFalse(store.adoptIntoPhoneMode(late), "adopted once")
    }

    func testOrdinaryRequestsAreAllowedWithoutWaiting() {
        let (store, api, _) = fixture()
        store.setPhoneMode(true)
        var answered: String?
        store.registerApproval(for: api, source: "claude", payload: request("pnpm test")) { answered = $0.text }

        XCTAssertTrue(answered?.contains("\"allow\"") == true)
        XCTAssertFalse(api.hasHookApproval)
        XCTAssertFalse(api.state.needsAttention)
    }

    func testRiskyRequestsWaitForTheUsersYesFromTheirPhone() {
        let (store, api, _) = fixture()
        store.setPhoneMode(true)
        var answered: String?
        store.registerApproval(for: api, source: "claude", payload: request("rm -rf build")) { answered = $0.text }
        XCTAssertNil(answered, "risky: held for Sumi and the user")
        XCTAssertTrue(api.hasHookApproval)

        guard case .failure(let refused) = store.answerForSumi(api, .approve, reason: nil) else {
            return XCTFail("approved a risky request without the user's yes")
        }
        XCTAssertTrue(refused.description.contains("ask the user on their phone"))
        XCTAssertTrue(api.hasHookApproval, "still waiting, not escalated away")

        guard case .success = store.answerForSumi(api, .approve, reason: nil, userApproved: true) else {
            return XCTFail("the user's yes should approve it")
        }
        XCTAssertTrue(answered?.contains("\"allow\"") == true)
    }

    func testUserApprovedMeansNothingOutsidePhoneMode() {
        let (store, api, _) = fixture()
        _ = store.delegate(api, scope: .turn, note: nil)
        store.registerApproval(for: api, source: "claude", payload: request("rm -rf build")) { _ in }

        guard case .failure(let refused) = store.answerForSumi(api, .approve, reason: nil, userApproved: true) else {
            return XCTFail("risky requests outside Phone Mode are the user's")
        }
        XCTAssertTrue(refused.description.hasPrefix("left for the user"))
    }

    func testNothingIsAllowedAutomaticallyWhenOff() {
        let (store, api, _) = fixture()
        var answered: String?
        store.registerApproval(for: api, source: "claude", payload: request("pnpm test")) { answered = $0.text }
        XCTAssertNil(answered)
        XCTAssertTrue(api.hasHookApproval)
    }

    func testAnAgentGoingIdleAgainWithNoNewReplyIsNotToldTwice() {
        let (store, api, _) = fixture()
        store.setPhoneMode(true)
        api.turnFromUser = false
        api.lastReply = "The search is finished: 2C is the best version."
        // Each report lands in its own digest, as they do minutes apart.
        func told() -> [String] {
            store.reportToSumi(api, from: .working)
            defer { store.sumiDigest = SumiDigest() }
            return finishes(store)
        }

        XCTAssertEqual(told(), ["@api finished: The search is finished: 2C is the best version."])
        XCTAssertEqual(told(), [], "a background task ended, or it was restarted on the same conversation")
        api.lastReply = "The search is finished: 2C is the best version."
        XCTAssertEqual(told(), [], "a turn nobody typed (a task notification) ended on the very same words")

        api.lastReply = "No setup we've tested reaches the bar."
        XCTAssertEqual(told(), ["@api finished: No setup we've tested reaches the bar."], "a new reply is news")
    }

    func testTheSameWordsAnsweringTheUsersOwnPromptAreStillTold() {
        let (store, api, _) = fixture()
        store.setPhoneMode(true)
        api.turnFromUser = true
        api.lastReply = "Done."
        store.reportToSumi(api, from: .working)
        api.lastReply = "Done."
        store.reportToSumi(api, from: .working)

        XCTAssertEqual(store.sumiHeard[api.id]?.count, api.replyCount, "the second Done. was heard as its own reply")
    }

    func testAReplyToThePromptTheUserTypedThemselvesSaysSo() {
        let (store, api, _) = fixture()
        store.setPhoneMode(true)
        api.turnFromUser = true
        api.lastReply = "Keep the vitamin C."
        store.reportToSumi(api, from: .working)
        XCTAssertTrue(finishes(store).first?.contains("the user typed to it themselves") == true, "\(finishes(store))")

        // One Sumi asked for (a watch, a message it sent) is Sumi's to act on in full.
        api.turnFromUser = true
        api.lastReply = "Swapped it."
        store.sumiWatches[api.id] = "tell the user the total"
        store.reportToSumi(api, from: .working)
        XCTAssertEqual(finishes(store).last, "@api finished: Swapped it. (your note: tell the user the total)")
    }

    func testAWatchedAgentEndingATurnWithNoNewReplyIsToldBriefly() {
        let (store, api, _) = fixture()
        api.turnFromUser = false
        api.lastReply = "Tests pass."
        store.sumiBrain.repeatWatches[api.id] = ""
        store.sumiWatches[api.id] = ""
        store.reportToSumi(api, from: .working)
        store.reportToSumi(api, from: .working)

        XCTAssertEqual(finishes(store), [
            "@api finished: Tests pass.",
            "@api finished: its turn ended with no new reply: the closing message is the one you already have",
        ])
    }

    func testPopoverCopyAndRules() {
        let since = Date(timeIntervalSince1970: 0)
        let text = PhoneModePopover.detail(since: since)
        XCTAssertTrue(text.hasPrefix("Remote Control since \(since.formatted(date: .omitted, time: .shortened))."))
        XCTAssertTrue(text.hasSuffix("Ordinary requests are allowed; questions and risky ones come to you."))

        let (store, _, _) = fixture()
        store.startPhoneMode()
        XCTAssertTrue(store.phoneModeAvailable, "the button shows while Claude runs Sumi")
        store.switchSumi(to: .codex)
        XCTAssertFalse(store.isPhoneModeOn, "switching to another CLI turns Phone Mode off")
    }

    // MARK: - Fixtures

    private func fixture(extra: String? = nil) -> (SessionStore, TerminalSession, TerminalSession) {
        let api = agent("api"), sumi = agent("sumi", sumi: true)
        sumi.apply(.processStarted, source: "test", force: .working)
        let store = SessionStore(previewSessions: [api, sumi] + (extra.map { [agent($0)] } ?? []), previewLayout: .grid)
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

    /// The finished lines waiting in Sumi's digest.
    private func finishes(_ store: SessionStore) -> [String] {
        store.sumiDigest.events.filter { if case .finished = $0.kind { return true } else { return false } }.map(\.line)
    }

    private func request(_ command: String) -> String {
        let payload: [String: Any] = ["tool_name": "Bash", "tool_input": ["command": command], "cwd": "/workspace/atlas"]
        return String(decoding: try! JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
    }
}
