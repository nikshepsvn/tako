import CryptoKit
import Foundation

/// Size limits. A message is a few sentences between two Sumis; anything near these is a mistake
/// or an attack, so it is refused rather than read.
enum LinkLimits {
    /// Most bytes of text in one chat, ask or answer.
    static let maxText = 32 * 1024
    /// Most bytes in one frame: the text plus JSON and the AEAD overhead.
    static let maxFrame = 48 * 1024
    /// Most characters of a display name.
    static let maxName = 40
}

/// One Sumi-to-Sumi message, sent inside an encrypted frame.
struct LinkMessage: Codable, Equatable {
    enum Kind: String, Codable {
        /// The first frame each side sends: proof it derived the session keys.
        case ready
        /// Human text.
        case chat
        /// A request for context; the friend's Sumi answers with `answer` and the same id.
        case ask
        case answer
    }

    var kind: Kind
    var id: String
    var text: String?
    /// For `answer`: the `ask` it replies to.
    var requestID: String?

    enum CodingKeys: String, CodingKey {
        case kind, id, text
        case requestID = "request_id"
    }

    static func newID(_ prefix: String) -> String {
        prefix + "-" + LinkCrypto.random(4).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether an id has exactly the shape `newID` makes. Ids come from the peer, so anything else
    /// (quotes, brackets, text) is refused before it can reach Sumi's prompt.
    static func isValidID(_ id: String) -> Bool {
        id.range(of: "^[a-z]-[0-9a-f]{8}$", options: .regularExpression) != nil
    }

    /// Every peer-supplied id in the message is well formed.
    var hasValidIDs: Bool { Self.isValidID(id) && requestID.map(Self.isValidID) ?? true }
}

/// Splits a TCP byte stream into length-prefixed frames.
struct LinkFramer {
    private var buffer = Data()

    static func frame(_ payload: Data) -> Data {
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { Data($0) } + payload
    }

    /// The complete frames `data` finishes. Throws on a frame over `maxFrame`: its sender is
    /// broken or hostile, and reading on would mean buffering whatever it claims.
    mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var frames: [Data] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(0) { $0 << 8 | Int($1) }
            guard length <= LinkLimits.maxFrame else { throw LinkError.tooLarge }
            guard buffer.count >= 4 + length else { break }
            frames.append(Data(buffer.dropFirst(4).prefix(length)))
            buffer = Data(buffer.dropFirst(4 + length))
        }
        return frames
    }
}

/// One connection's protocol state, apart from the socket, so tests can run two against each other
/// in memory. The wire format is documented on `LinkCrypto`.
final class LinkChannel {
    typealias Role = LinkHandshake.Role

    enum Event: Equatable {
        /// The handshake finished: the peer proved it holds `peerKey`'s private half.
        case open(peerKey: Data)
        case message(LinkMessage)
        /// Responder: someone asked to pair; the code follows once they reveal their nonce.
        case pairRequested(name: String, key: Data)
        /// Both sides can now show `code`.
        case pairCode(name: String, key: Data, code: String)
        /// Both users confirmed the code.
        case paired(name: String, key: Data)
        case closed(String)
    }

    let identity: LinkIdentity
    let role: Role
    let localName: String
    /// Whether a static key belongs to a paired peer.
    var isPaired: (Data) -> Bool = { _ in false }
    /// Whether to entertain a pair request from this key now (rate limit, one at a time).
    var allowsPairRequest: (Data) -> Bool = { _ in true }
    /// Sends one frame's payload (the caller adds the length prefix).
    var write: (Data) -> Void = { _ in }
    var onEvent: (Event) -> Void = { _ in }

    private var ephemeral: Curve25519.KeyAgreement.PrivateKey?
    /// The initiator of a session dials one peer and accepts only that key.
    private var expectedPeer: Data?
    private var cipher: LinkCipher?
    private(set) var peerKey: Data?
    private(set) var isOpen = false
    private(set) var isClosed = false
    private var pairing: PairProgress?

    private struct PairProgress {
        var nonce: Data
        var peerKey: Data?
        var peerName = ""
        var peerCommit: Data?
        var code: String?
        var confirmedHere = false
        var confirmedThere = false
    }

    init(identity: LinkIdentity, role: Role, localName: String) {
        self.identity = identity
        self.role = role
        self.localName = localName
    }

    // MARK: - Starting

    /// Initiator: open an encrypted session with the paired peer whose key is `peer`.
    func startSession(with peer: Data) {
        let key = Curve25519.KeyAgreement.PrivateKey()
        ephemeral = key
        expectedPeer = peer
        sendPlain(["t": "hello", "v": LinkCrypto.version, "static": identity.publicKey.base64EncodedString(),
                   "eph": key.publicKey.rawRepresentation.base64EncodedString()])
    }

    /// Initiator: ask to pair, committing to a nonce before seeing the responder's.
    func startPairing() {
        let nonce = LinkCrypto.random(LinkCrypto.nonceLength)
        pairing = PairProgress(nonce: nonce)
        sendPlain(["t": "pair", "v": LinkCrypto.version, "static": identity.publicKey.base64EncodedString(), "name": localName,
                   "commit": LinkPairingCode.commitment(key: identity.publicKey, nonce: nonce).base64EncodedString()])
    }

    // MARK: - Sending

    func send(_ message: LinkMessage) throws {
        guard isOpen, !isClosed else { throw LinkError.notOpen }
        try sendSealed(message)
    }

    /// This side's user compared the codes and confirmed.
    func confirmPairing() {
        guard var progress = pairing, progress.code != nil, !progress.confirmedHere else { return }
        progress.confirmedHere = true
        pairing = progress
        sendPlain(["t": "pair-confirm"])
        finishPairingIfConfirmed()
    }

    func cancelPairing() {
        guard pairing != nil, !isClosed else { return }
        refuse("pairing cancelled")
    }

    func close(_ reason: String) {
        guard !isClosed else { return }
        isClosed = true
        onEvent(.closed(reason))
    }

    // MARK: - Receiving

    func receive(_ frame: Data) {
        guard !isClosed else { return }
        guard var cipher else { return receivePlain(frame) }
        let plaintext: Data
        do {
            plaintext = try cipher.open(frame)
        } catch {
            return close("\(error)")
        }
        self.cipher = cipher
        guard let message = try? JSONDecoder().decode(LinkMessage.self, from: plaintext) else { return close("\(LinkError.malformed)") }
        if message.kind == .ready {
            guard !isOpen, let peerKey else { return }
            isOpen = true
            onEvent(.open(peerKey: peerKey))
            return
        }
        guard isOpen else { return close("message before the handshake finished") }
        guard (message.text?.utf8.count ?? 0) <= LinkLimits.maxText else { return close("\(LinkError.tooLarge)") }
        onEvent(.message(message))
    }

    private func receivePlain(_ frame: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: frame)) as? [String: Any],
              let type = object["t"] as? String else { return refuse("\(LinkError.malformed)") }
        func data(_ key: String, length: Int? = nil) -> Data? {
            guard let value = (object[key] as? String).flatMap({ Data(base64Encoded: $0) }) else { return nil }
            return length.map { value.count == $0 ? value : nil } ?? value
        }
        switch type {
        case "hello":
            guard let theirStatic = data("static", length: LinkCrypto.keyLength),
                  let theirEphemeral = data("eph", length: LinkCrypto.keyLength) else { return refuse("\(LinkError.malformed)") }
            receiveHello(staticKey: theirStatic, ephemeralKey: theirEphemeral)
        case "pair":
            guard role == .responder, pairing == nil, ephemeral == nil,
                  let key = data("static", length: LinkCrypto.keyLength), let commit = data("commit", length: 32) else {
                return refuse("\(LinkError.malformed)")
            }
            guard key != identity.publicKey else { return refuse("that's this Tako") }
            guard allowsPairRequest(key) else { return refuse("busy; try again in a minute") }
            let name = Self.cleanName(object["name"] as? String)
            let nonce = LinkCrypto.random(LinkCrypto.nonceLength)
            pairing = PairProgress(nonce: nonce, peerKey: key, peerName: name, peerCommit: commit)
            sendPlain(["t": "pair-accept", "static": identity.publicKey.base64EncodedString(), "name": localName,
                       "nonce": nonce.base64EncodedString()])
            onEvent(.pairRequested(name: name, key: key))
        case "pair-accept":
            guard role == .initiator, var progress = pairing, progress.peerKey == nil,
                  let key = data("static", length: LinkCrypto.keyLength), let theirNonce = data("nonce", length: LinkCrypto.nonceLength) else {
                return refuse("\(LinkError.malformed)")
            }
            progress.peerKey = key
            progress.peerName = Self.cleanName(object["name"] as? String)
            let code = LinkPairingCode.code(initiatorKey: identity.publicKey, initiatorNonce: progress.nonce,
                                            responderKey: key, responderNonce: theirNonce)
            progress.code = code
            pairing = progress
            sendPlain(["t": "pair-reveal", "nonce": progress.nonce.base64EncodedString()])
            onEvent(.pairCode(name: progress.peerName, key: key, code: code))
        case "pair-reveal":
            guard role == .responder, var progress = pairing, progress.code == nil, let key = progress.peerKey,
                  let commit = progress.peerCommit, let theirNonce = data("nonce", length: LinkCrypto.nonceLength) else {
                return refuse("\(LinkError.malformed)")
            }
            guard LinkPairingCode.commitment(key: key, nonce: theirNonce) == commit else { return refuse("\(LinkError.commitment)") }
            let code = LinkPairingCode.code(initiatorKey: key, initiatorNonce: theirNonce,
                                            responderKey: identity.publicKey, responderNonce: progress.nonce)
            progress.code = code
            pairing = progress
            onEvent(.pairCode(name: progress.peerName, key: key, code: code))
        case "pair-confirm":
            guard var progress = pairing, progress.code != nil else { return refuse("\(LinkError.malformed)") }
            progress.confirmedThere = true
            pairing = progress
            finishPairingIfConfirmed()
        case "bye":
            close(Self.cleanName(object["reason"] as? String, limit: 120, fallback: "closed by the peer"))
        default:
            refuse("\(LinkError.malformed)")
        }
    }

    private func receiveHello(staticKey: Data, ephemeralKey: Data) {
        guard pairing == nil, peerKey == nil else { return refuse("\(LinkError.malformed)") }
        switch role {
        case .responder:
            guard isPaired(staticKey) else { return refuse("\(LinkError.unknownKey)") }
            let key = Curve25519.KeyAgreement.PrivateKey()
            ephemeral = key
            guard let derived = try? LinkHandshake.cipher(role: .responder, identity: identity, ephemeral: key,
                                                          peerStatic: staticKey, peerEphemeral: ephemeralKey) else {
                return refuse("\(LinkError.malformed)")
            }
            // Keys first: the peer may answer before this call returns.
            cipher = derived
            peerKey = staticKey
            sendPlain(["t": "hello", "v": LinkCrypto.version, "static": identity.publicKey.base64EncodedString(),
                       "eph": key.publicKey.rawRepresentation.base64EncodedString()])
            try? sendSealed(LinkMessage(kind: .ready, id: "ready"))
        case .initiator:
            guard let ephemeral, let expectedPeer else { return refuse("\(LinkError.malformed)") }
            guard staticKey == expectedPeer else { return refuse("\(LinkError.unexpectedKey)") }
            guard let derived = try? LinkHandshake.cipher(role: .initiator, identity: identity, ephemeral: ephemeral,
                                                          peerStatic: staticKey, peerEphemeral: ephemeralKey) else {
                return refuse("\(LinkError.malformed)")
            }
            cipher = derived
            peerKey = staticKey
            try? sendSealed(LinkMessage(kind: .ready, id: "ready"))
        }
    }

    private func finishPairingIfConfirmed() {
        guard let progress = pairing, progress.confirmedHere, progress.confirmedThere, let key = progress.peerKey else { return }
        onEvent(.paired(name: progress.peerName, key: key))
        pairing = nil
        close("paired")
    }

    // MARK: - Frames

    private func sendSealed(_ message: LinkMessage) throws {
        guard var cipher else { throw LinkError.notOpen }
        let payload = try JSONEncoder().encode(message)
        guard payload.count + 28 <= LinkLimits.maxFrame else { throw LinkError.tooLarge }
        let sealed = try cipher.seal(payload)
        self.cipher = cipher
        write(sealed)
    }

    private func sendPlain(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        write(data)
    }

    /// Says why in a plaintext `bye` (the peer may not hold keys yet), then closes.
    private func refuse(_ reason: String) {
        if cipher == nil { sendPlain(["t": "bye", "reason": reason]) }
        close(reason)
    }

    /// A name or reason from the network: printable, one line, short.
    static func cleanName(_ raw: String?, limit: Int = LinkLimits.maxName, fallback: String = "Someone") -> String {
        let text = (raw ?? "").unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && $0 != "<" && $0 != ">" && $0 != "\"" }
        let line = String(String.UnicodeScalarView(text)).trimmingCharacters(in: .whitespacesAndNewlines)
        return line.isEmpty ? fallback : String(line.prefix(limit))
    }
}
