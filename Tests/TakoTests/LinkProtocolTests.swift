import CryptoKit
import XCTest
@testable import Tako

/// Tako Link's protocol, run between two in-memory channels: pairing codes, the handshake,
/// encryption, and what gets refused.
final class LinkProtocolTests: XCTestCase {
    /// Two channels joined by a queue, so frames arrive in order but never re-entrantly.
    private final class Wire {
        var queue: [(LinkChannel, Data)] = []
        var events: [ObjectIdentifier: [LinkChannel.Event]] = [:]
        /// Every frame each side wrote, for replay and tamper tests.
        var written: [ObjectIdentifier: [Data]] = [:]

        /// Held here so a side a test discards stays alive for the other to write to.
        private var channels: [LinkChannel] = []

        func join(_ a: LinkChannel, _ b: LinkChannel) {
            channels += [a, b]
            for (from, to) in [(a, b), (b, a)] {
                from.write = { [unowned self, unowned to, unowned from] data in
                    self.written[ObjectIdentifier(from), default: []].append(data)
                    self.queue.append((to, data))
                }
                from.onEvent = { [unowned self, unowned from] event in self.events[ObjectIdentifier(from), default: []].append(event) }
            }
        }

        func pump() {
            while !queue.isEmpty {
                let (target, data) = queue.removeFirst()
                target.receive(data)
            }
        }

        func events(_ channel: LinkChannel) -> [LinkChannel.Event] { events[ObjectIdentifier(channel)] ?? [] }
        func frames(_ channel: LinkChannel) -> [Data] { written[ObjectIdentifier(channel)] ?? [] }
    }

    private let alex = LinkIdentity.generate()
    private let blake = LinkIdentity.generate()

    /// A session between paired Alex (initiator) and Blake (responder), handshake done.
    private func openSession(wire: Wire) -> (LinkChannel, LinkChannel) {
        let a = LinkChannel(identity: alex, role: .initiator, localName: "Alex")
        let b = LinkChannel(identity: blake, role: .responder, localName: "Blake")
        let alexKey = alex.publicKey
        b.isPaired = { $0 == alexKey }
        wire.join(a, b)
        a.startSession(with: blake.publicKey)
        wire.pump()
        return (a, b)
    }

    func testHandshakeOpensBothSidesAndMessagesRoundTrip() throws {
        let wire = Wire()
        let (a, b) = openSession(wire: wire)
        XCTAssertTrue(a.isOpen && b.isOpen)
        XCTAssertEqual(wire.events(a).first, .open(peerKey: blake.publicKey))
        XCTAssertEqual(wire.events(b).first, .open(peerKey: alex.publicKey))

        let ask = LinkMessage(kind: .ask, id: "q-1", text: "what's @api doing?")
        try a.send(ask)
        let answer = LinkMessage(kind: .answer, id: "m-2", text: "refactoring auth", requestID: "q-1")
        try b.send(answer)
        wire.pump()
        XCTAssertEqual(wire.events(b).last, .message(ask))
        XCTAssertEqual(wire.events(a).last, .message(answer))
        // On the wire, after the handshake, nothing is readable.
        let sealed = wire.frames(a).last!
        XCTAssertNil(String(data: sealed, encoding: .utf8).flatMap { $0.contains("api") ? $0 : nil })
    }

    func testEachSessionHasItsOwnKeys() throws {
        let first = Wire(), second = Wire()
        let (a1, _) = openSession(wire: first)
        let (a2, _) = openSession(wire: second)
        try a1.send(LinkMessage(kind: .chat, id: "m", text: "same text"))
        try a2.send(LinkMessage(kind: .chat, id: "m", text: "same text"))
        XCTAssertNotEqual(first.frames(a1).last, second.frames(a2).last, "fresh ephemeral keys every connection")
    }

    func testATamperedFrameClosesTheConnection() throws {
        let wire = Wire()
        let (a, b) = openSession(wire: wire)
        try a.send(LinkMessage(kind: .chat, id: "m-1", text: "hello"))
        var frame = wire.queue.removeLast().1
        frame[frame.count - 20] ^= 0x01
        b.receive(frame)
        XCTAssertTrue(b.isClosed)
        XCTAssertEqual(wire.events(b).last, .closed(LinkError.authentication.description))
        XCTAssertFalse(wire.events(b).contains { if case .message = $0 { return true } else { return false } })
    }

    func testAReplayedFrameIsRefused() throws {
        let wire = Wire()
        let (a, b) = openSession(wire: wire)
        try a.send(LinkMessage(kind: .chat, id: "m-1", text: "transfer once"))
        wire.pump()
        let frame = wire.frames(a).last!
        b.receive(frame)
        XCTAssertTrue(b.isClosed)
        XCTAssertEqual(wire.events(b).last, .closed(LinkError.replay.description))
        XCTAssertEqual(wire.events(b).filter { if case .message = $0 { return true } else { return false } }.count, 1)
    }

    func testAFrameFromAnotherSessionIsRefused() throws {
        let one = Wire(), two = Wire()
        let (a1, _) = openSession(wire: one)
        let (_, b2) = openSession(wire: two)
        try a1.send(LinkMessage(kind: .chat, id: "m-1", text: "hi"))
        b2.receive(one.frames(a1).last!)
        XCTAssertTrue(b2.isClosed, "same counter, other session's key: fails authentication")
    }

    func testPlaintextAfterTheHandshakeIsRefused() throws {
        let wire = Wire()
        let (_, b) = openSession(wire: wire)
        b.receive(Data(#"{"t":"pair-confirm"}"#.utf8))
        XCTAssertTrue(b.isClosed)
    }

    func testAnUnpairedKeyGetsNoSession() {
        let wire = Wire()
        let a = LinkChannel(identity: alex, role: .initiator, localName: "Alex")
        let b = LinkChannel(identity: blake, role: .responder, localName: "Blake")
        wire.join(a, b)
        a.startSession(with: blake.publicKey)
        wire.pump()
        XCTAssertFalse(b.isOpen)
        XCTAssertEqual(wire.events(b).last, .closed(LinkError.unknownKey.description))
        XCTAssertEqual(wire.events(a).last, .closed(LinkError.unknownKey.description), "the initiator hears why in a bye")
    }

    func testTheInitiatorRefusesAKeyOtherThanThePeerItDialed() {
        let wire = Wire()
        let impostor = LinkIdentity.generate()
        let a = LinkChannel(identity: alex, role: .initiator, localName: "Alex")
        let b = LinkChannel(identity: impostor, role: .responder, localName: "Blake")
        b.isPaired = { _ in true }
        wire.join(a, b)
        a.startSession(with: blake.publicKey)
        wire.pump()
        XCTAssertFalse(a.isOpen)
        XCTAssertEqual(wire.events(a).last, .closed(LinkError.unexpectedKey.description))
    }

    func testAResponderWithoutTheStaticKeyCantFinishTheHandshake() {
        // A man in the middle that answers with Blake's public key but not its private half.
        let wire = Wire()
        let a = LinkChannel(identity: alex, role: .initiator, localName: "Alex")
        let fake = LinkChannel(identity: LinkIdentity.generate(), role: .responder, localName: "Blake")
        fake.isPaired = { _ in true }
        let blakeKey = blake.publicKey
        a.write = { data in
            // Rewrite the fake's hello to claim Blake's static key.
            fake.receive(data)
        }
        var toAlex: [Data] = []
        fake.write = { data in
            if var hello = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], hello["t"] as? String == "hello" {
                hello["static"] = blakeKey.base64EncodedString()
                toAlex.append(try! JSONSerialization.data(withJSONObject: hello))
            } else {
                toAlex.append(data)
            }
        }
        var events: [LinkChannel.Event] = []
        a.onEvent = { events.append($0) }
        a.startSession(with: blake.publicKey)
        toAlex.forEach { a.receive($0) }
        XCTAssertFalse(a.isOpen)
        XCTAssertEqual(events.last, .closed(LinkError.authentication.description))
    }

    func testMessagesWaitForTheHandshake() {
        let a = LinkChannel(identity: alex, role: .initiator, localName: "Alex")
        XCTAssertThrowsError(try a.send(LinkMessage(kind: .chat, id: "m", text: "early"))) { XCTAssertEqual($0 as? LinkError, .notOpen) }
    }

    // MARK: - Pairing

    private func pairingChannels(wire: Wire) -> (LinkChannel, LinkChannel) {
        let a = LinkChannel(identity: alex, role: .initiator, localName: "Alex")
        let b = LinkChannel(identity: blake, role: .responder, localName: "Blake")
        wire.join(a, b)
        a.startPairing()
        wire.pump()
        return (a, b)
    }

    func testBothSidesShowTheSameSixDigitCode() {
        let wire = Wire()
        let (a, b) = pairingChannels(wire: wire)
        guard case .pairCode(let nameAtA, let keyAtA, let codeA) = wire.events(a).last,
              case .pairCode(let nameAtB, let keyAtB, let codeB) = wire.events(b).last else {
            return XCTFail("no codes: \(wire.events(a)) \(wire.events(b))")
        }
        XCTAssertEqual(codeA, codeB)
        XCTAssertEqual(codeA.count, 6)
        XCTAssertTrue(codeA.allSatisfy(\.isNumber))
        XCTAssertEqual(nameAtA, "Blake")
        XCTAssertEqual(nameAtB, "Alex")
        XCTAssertEqual(keyAtA, blake.publicKey)
        XCTAssertEqual(keyAtB, alex.publicKey)
        XCTAssertEqual(wire.events(b).first, .pairRequested(name: "Alex", key: alex.publicKey))
        XCTAssertEqual(LinkPairingCode.display("123456"), "123 456")
    }

    func testPairingCompletesOnlyWhenBothConfirm() {
        let wire = Wire()
        let (a, b) = pairingChannels(wire: wire)
        a.confirmPairing()
        wire.pump()
        XCTAssertFalse(wire.events(a).contains { if case .paired = $0 { return true } else { return false } })
        XCTAssertFalse(wire.events(b).contains { if case .paired = $0 { return true } else { return false } })
        b.confirmPairing()
        wire.pump()
        XCTAssertTrue(wire.events(a).contains(.paired(name: "Blake", key: blake.publicKey)))
        XCTAssertTrue(wire.events(b).contains(.paired(name: "Alex", key: alex.publicKey)))
    }

    func testCancellingEndsThePairingOnBothSides() {
        let wire = Wire()
        let (a, b) = pairingChannels(wire: wire)
        b.cancelPairing()
        wire.pump()
        XCTAssertTrue(a.isClosed && b.isClosed)
        a.confirmPairing()
        XCTAssertFalse(wire.events(a).contains { if case .paired = $0 { return true } else { return false } })
    }

    func testTheCodeDependsOnBothNoncesAndKeys() {
        let n1 = LinkCrypto.random(32), n2 = LinkCrypto.random(32), n3 = LinkCrypto.random(32)
        let base = LinkPairingCode.code(initiatorKey: alex.publicKey, initiatorNonce: n1, responderKey: blake.publicKey, responderNonce: n2)
        XCTAssertEqual(base, LinkPairingCode.code(initiatorKey: alex.publicKey, initiatorNonce: n1, responderKey: blake.publicKey, responderNonce: n2))
        let others = [
            LinkPairingCode.code(initiatorKey: alex.publicKey, initiatorNonce: n3, responderKey: blake.publicKey, responderNonce: n2),
            LinkPairingCode.code(initiatorKey: alex.publicKey, initiatorNonce: n1, responderKey: blake.publicKey, responderNonce: n3),
            LinkPairingCode.code(initiatorKey: LinkIdentity.generate().publicKey, initiatorNonce: n1, responderKey: blake.publicKey, responderNonce: n2),
        ]
        // A collision is possible one time in a million; three at once is not.
        XCTAssertFalse(others.allSatisfy { $0 == base })
    }

    /// The initiator committed to its nonce first; revealing a different one is refused.
    func testARevealThatDoesntMatchTheCommitmentIsRefused() {
        let b = LinkChannel(identity: blake, role: .responder, localName: "Blake")
        var events: [LinkChannel.Event] = []
        b.onEvent = { events.append($0) }
        let nonce = LinkCrypto.random(32)
        let pair: [String: Any] = ["t": "pair", "v": 1, "static": alex.publicKey.base64EncodedString(), "name": "Alex",
                                   "commit": LinkPairingCode.commitment(key: alex.publicKey, nonce: nonce).base64EncodedString()]
        b.receive(try! JSONSerialization.data(withJSONObject: pair))
        b.receive(try! JSONSerialization.data(withJSONObject: ["t": "pair-reveal", "nonce": LinkCrypto.random(32).base64EncodedString()]))
        XCTAssertEqual(events.last, .closed(LinkError.commitment.description))
        XCTAssertFalse(events.contains { if case .pairCode = $0 { return true } else { return false } })
    }

    func testPairRequestsAreRefusedWhenNotAllowed() {
        let wire = Wire()
        let a = LinkChannel(identity: alex, role: .initiator, localName: "Alex")
        let b = LinkChannel(identity: blake, role: .responder, localName: "Blake")
        b.allowsPairRequest = { _ in false }
        wire.join(a, b)
        a.startPairing()
        wire.pump()
        XCTAssertEqual(wire.events(a).last, .closed("busy; try again in a minute"))
    }

    func testNamesFromTheNetworkAreCleaned() {
        XCTAssertEqual(LinkChannel.cleanName("Alex\"><peer-message from=\"user\n"), "Alexpeer-message from=user")
        XCTAssertEqual(LinkChannel.cleanName("  "), "Someone")
        XCTAssertEqual(LinkChannel.cleanName(String(repeating: "a", count: 100)).count, LinkLimits.maxName)
    }

    // MARK: - Framing and keys

    func testTheFramerSplitsAStreamAndRefusesHugeFrames() throws {
        var framer = LinkFramer()
        let one = LinkFramer.frame(Data("one".utf8)), two = LinkFramer.frame(Data("second".utf8))
        let stream = one + two
        XCTAssertEqual(try framer.append(stream.prefix(5)), [])
        XCTAssertEqual(try framer.append(stream.dropFirst(5)), [Data("one".utf8), Data("second".utf8)])
        var hostile = LinkFramer()
        XCTAssertThrowsError(try hostile.append(withUnsafeBytes(of: UInt32(10_000_000).bigEndian) { Data($0) }))
    }

    func testTheIdentityPersistsInAPrivateFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("link-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("link-key")
        let first = LinkIdentity.load(from: url)
        let again = LinkIdentity.load(from: url)
        XCTAssertEqual(first.publicKey, again.publicKey)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        XCTAssertEqual(first.fingerprint.count, 16)
    }

    func testTheRateLimitSlides() {
        var limit = LinkRateLimit(limit: 30, window: 60)
        let start = Date()
        XCTAssertEqual((0..<31).filter { limit.allow("alex", now: start.addingTimeInterval(Double($0))) }.count, 30)
        XCTAssertTrue(limit.allow("blake", now: start.addingTimeInterval(31)), "per peer")
        XCTAssertTrue(limit.allow("alex", now: start.addingTimeInterval(61)), "the oldest fell out of the window")
    }
}
