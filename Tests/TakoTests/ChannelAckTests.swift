import XCTest
@testable import Tako

/// Channel messages count as delivered only once `ht mcp` confirms it wrote them to Claude.
@MainActor
final class ChannelAckTests: XCTestCase {
    override func tearDown() {
        SessionStore.channelsEnabledOverride = nil
        super.tearDown()
    }

    // MARK: - Channel acks

    func testAConfirmingPollerMakesAMessageDeliveredOnlyOnceItAcks() {
        let (store, api) = channelFixture()
        var handed: ControlResponse?
        store.subscribeChannel(api, acks: [], reply: { handed = $0 })
        XCTAssertTrue(store.channelConfirms(api), "an empty acks list says this poller confirms")
        XCTAssertEqual(api.deliver("Message from @web: rebased", from: "web"), "sent to @api (channel)",
                       "not yet delivered: the poller hasn't said it reached Claude")
        XCTAssertEqual(handed?.messages, ["Message from @web: rebased"])
        let id = try? XCTUnwrap(handed?.messageIDs?.first)
        XCTAssertNotNil(id.flatMap { store.channelUnconfirmed[$0] })

        store.subscribeChannel(api, acks: [id ?? ""], reply: { _ in })
        XCTAssertTrue(store.channelUnconfirmed.isEmpty, "acknowledged on the next poll")
        store.channelConfirmationDue(id ?? "")
        XCTAssertNotNil(store.channelLastSeen[api.id], "a confirmed message is never typed again")
    }

    func testAMessageNobodyConfirmsIsTypedInsteadAndTheChannelCalledDead() {
        let (store, api) = channelFixture()
        var handed: ControlResponse?
        store.subscribeChannel(api, acks: [], reply: { handed = $0 })
        _ = api.deliver("Message from @web: rebased", from: "web")
        guard let id = handed?.messageIDs?.first else { return XCTFail("no id") }
        store.channelConfirmationDue(id)
        XCTAssertTrue(store.channelUnconfirmed.isEmpty)
        XCTAssertNil(store.channelLastSeen[api.id], "later messages are typed until the poller shows up again")
        XCTAssertFalse(store.pushViaChannel("next one", to: api))
    }

    func testAnOlderHtThatNeverAcksKeepsTheOldBehaviour() {
        let (store, api) = channelFixture()
        var handed: ControlResponse?
        store.subscribeChannel(api, acks: nil, reply: { handed = $0 })
        XCTAssertFalse(store.channelConfirms(api))
        XCTAssertEqual(api.deliver("hello", from: "web"), "delivered to @api (channel)")
        XCTAssertEqual(handed?.messages, ["hello"])
        XCTAssertTrue(store.channelUnconfirmed.isEmpty, "nothing waits on an ack that will never come")

        // Picked up from the inbox on the next poll works the same way.
        XCTAssertTrue(store.pushViaChannel("queued one", to: api))
        store.subscribeChannel(api, acks: nil, reply: { handed = $0 })
        XCTAssertEqual(handed?.messages, ["queued one"])
        XCTAssertTrue(store.channelUnconfirmed.isEmpty)
    }

    func testTheInboxHandsOverIdsAndTracksThemForAConfirmingPoller() {
        let (store, api) = channelFixture()
        store.subscribeChannel(api, acks: [], reply: { _ in })
        store.subscribeChannel(api, acks: [], reply: { _ in })  // the poll that replaced the waiter
        _ = store.dropChannel(for: api)
        store.subscribeChannel(api, acks: [], reply: { _ in })
        var handed: ControlResponse?
        store.subscribeChannel(api, acks: [], reply: { handed = $0 })
        XCTAssertTrue(store.pushViaChannel("one", to: api))
        XCTAssertEqual(handed?.messages, ["one"])
        XCTAssertEqual(store.channelUnconfirmed.count, 1)
    }

    func testThePollerWritesEachMessageThenAcksItOnTheNextPoll() throws {
        var poller = ChannelPoller()
        XCTAssertEqual(poller.nextRequest().acks, [], "even the first poll says it confirms")
        var response = ControlResponse.success()
        response.messages = ["a", "b"]
        response.messageIDs = ["c1", "c2"]
        var written: [String] = []
        poller.received(response) { written.append(($0["params"] as? [String: Any])?["content"] as? String ?? "") }
        XCTAssertEqual(written, ["a", "b"])
        XCTAssertEqual(poller.nextRequest().acks, ["c1", "c2"])
        poller.received(.success()) { _ in XCTFail("nothing to write") }
        XCTAssertEqual(poller.nextRequest().acks, [])

        // An older app sends no ids: messages are still written, nothing is acked.
        let old = try JSONDecoder().decode(ControlResponse.self, from: Data(#"{"ok":true,"messages":["x"]}"#.utf8))
        poller.received(old) { written.append(($0["params"] as? [String: Any])?["content"] as? String ?? "") }
        XCTAssertEqual(written.last, "x")
        XCTAssertEqual(poller.nextRequest().acks, [])
        let encoded = String(decoding: try JSONEncoder().encode(poller.nextRequest()), as: UTF8.self)
        XCTAssertTrue(encoded.contains(#""acks":[]"#), encoded)
    }

    // MARK: - Fixture

    private func channelFixture() -> (SessionStore, TerminalSession) {
        SessionStore.channelsEnabledOverride = true
        let api = TerminalSession(spec: LaunchSpec(label: "api", kind: .claude, cwd: "/workspace/atlas"), resume: false)
        api.apply(.processStarted, source: "test", force: .idle)
        let store = SessionStore(previewSessions: [api], previewLayout: .grid)
        api.store = store
        return (store, api)
    }
}
