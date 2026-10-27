import CryptoKit
import Foundation

/// Tako Link's cryptography: a long-lived identity per install, the pairing code two people
/// compare, and the per-connection keys. Everything is CryptoKit; nothing here touches a socket.
///
/// Protocol (version 1), over TCP with 4-byte big-endian length-prefixed frames:
///
/// **Identity.** Each install has a static Curve25519 (X25519) key pair. A peer *is* its public
/// key; the name it announces is only a label. The fingerprint is the first 8 bytes of
/// SHA-256(public key), in hex, and rides in the Bonjour TXT record.
///
/// **Pairing** (plaintext JSON frames, before either side trusts the other). The initiator I sends
/// `pair{static, name, commit = SHA-256("tako-link commit" ‖ I.static ‖ nI)}`; the responder R
/// answers `pair-accept{static, name, nR}`; I reveals `pair-reveal{nI}` and R checks it against the
/// commitment. Both show the 6-digit code SHA-256("tako-link sas" ‖ I.static ‖ R.static ‖ nI ‖ nR)
/// mod 10⁶. Because I committed to nI before seeing nR, a man in the middle gets one guess in a
/// million at making the two screens agree. Each user compares the codes and clicks Confirm
/// (`pair-confirm`); a side stores the other's key only once both have confirmed.
///
/// **Sessions** (paired peers only). Each side sends `hello{static, eph}` with a fresh ephemeral
/// key; a responder that doesn't know the initiator's static key, or an initiator that hears a
/// static key other than the peer it dialed, closes the connection. Both compute the triple
/// Diffie-Hellman of the Signal/Noise-KK family, DH(eI, eR) ‖ DH(sI, eR) ‖ DH(eI, sR), and run it
/// through HKDF-SHA256 (salt: SHA-256 of both hellos' keys) into one ChaCha20-Poly1305 key per
/// direction. Only the holders of both static private keys can derive them, so the first
/// encrypted frame each side sends (`ready`) authenticates it; ephemeral keys give forward secrecy.
///
/// **Frames.** After the handshake every frame is a ChaChaPoly sealed box whose 12-byte nonce is
/// 4 zero bytes and a 64-bit counter. Each direction's counter starts at 0 and must arrive exactly
/// in order (TCP is ordered), so a replayed, reordered or dropped frame fails, as does any frame
/// that fails authentication: the connection closes. A plaintext frame after the handshake is
/// refused too.
enum LinkCrypto {
    static let version = 1
    static let keyLength = 32
    static let nonceLength = 32

    static func random(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    static func tag(_ name: String) -> Data { Data("tako-link \(name)".utf8) }
}

enum LinkError: Error, Equatable, CustomStringConvertible {
    case malformed, replay, authentication, unknownKey, unexpectedKey, tooLarge, notOpen, commitment

    var description: String {
        switch self {
        case .malformed: return "malformed frame"
        case .replay: return "frame out of order (replayed or dropped)"
        case .authentication: return "frame failed authentication"
        case .unknownKey: return "not paired with this key"
        case .unexpectedKey: return "a different key answered than the one paired"
        case .tooLarge: return "message too large"
        case .notOpen: return "connection not open"
        case .commitment: return "pairing commitment didn't match"
        }
    }
}

/// This install's long-lived key pair.
struct LinkIdentity {
    let privateKey: Curve25519.KeyAgreement.PrivateKey

    var publicKey: Data { privateKey.publicKey.rawRepresentation }
    var fingerprint: String { Self.fingerprint(of: publicKey) }

    static func fingerprint(of key: Data) -> String {
        SHA256.hash(data: key).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func generate() -> LinkIdentity { LinkIdentity(privateKey: Curve25519.KeyAgreement.PrivateKey()) }

    /// Tako keeps no secrets in the Keychain, so the key lives in a file only this user can read,
    /// beside the app's other state. Made on first use.
    static func load(from url: URL) -> LinkIdentity {
        let manager = FileManager.default
        if let text = try? String(contentsOf: url, encoding: .utf8),
           let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
           let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw) {
            try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return LinkIdentity(privateKey: key)
        }
        let identity = generate()
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        manager.createFile(atPath: url.path, contents: Data(identity.privateKey.rawRepresentation.base64EncodedString().utf8),
                           attributes: [.posixPermissions: 0o600])
        return identity
    }
}

/// The short code both people compare while pairing (see `LinkCrypto`).
enum LinkPairingCode {
    static func commitment(key: Data, nonce: Data) -> Data {
        Data(SHA256.hash(data: LinkCrypto.tag("commit") + key + nonce))
    }

    static func code(initiatorKey: Data, initiatorNonce: Data, responderKey: Data, responderNonce: Data) -> String {
        let digest = SHA256.hash(data: LinkCrypto.tag("sas") + initiatorKey + responderKey + initiatorNonce + responderNonce)
        let value = digest.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) } % 1_000_000
        return String(format: "%06u", value)
    }

    /// "123 456": easier to read aloud.
    static func display(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return code.prefix(3) + " " + code.suffix(3)
    }
}

/// Derives a connection's keys from both static keys and both ephemeral keys.
enum LinkHandshake {
    enum Role { case initiator, responder }

    static func cipher(role: Role, identity: LinkIdentity, ephemeral: Curve25519.KeyAgreement.PrivateKey,
                       peerStatic: Data, peerEphemeral: Data) throws -> LinkCipher {
        guard let theirStatic = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerStatic),
              let theirEphemeral = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerEphemeral) else {
            throw LinkError.malformed
        }
        func dh(_ mine: Curve25519.KeyAgreement.PrivateKey, _ theirs: Curve25519.KeyAgreement.PublicKey) throws -> Data {
            guard let secret = try? mine.sharedSecretFromKeyAgreement(with: theirs) else { throw LinkError.malformed }
            return secret.withUnsafeBytes { Data($0) }
        }
        let ee = try dh(ephemeral, theirEphemeral)
        // DH(sI, eR) and DH(eI, sR), each computed from whichever half this side holds.
        let staticI = role == .initiator ? try dh(identity.privateKey, theirEphemeral) : try dh(ephemeral, theirStatic)
        let staticR = role == .initiator ? try dh(ephemeral, theirStatic) : try dh(identity.privateKey, theirEphemeral)
        let mine = identity.publicKey + ephemeral.publicKey.rawRepresentation
        let theirs = peerStatic + peerEphemeral
        let transcript = role == .initiator ? mine + theirs : theirs + mine
        let salt = Data(SHA256.hash(data: LinkCrypto.tag("v\(LinkCrypto.version) handshake") + transcript))
        let keys = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ee + staticI + staticR), salt: salt,
                                          info: LinkCrypto.tag("v\(LinkCrypto.version) keys"), outputByteCount: 64)
        let bytes = keys.withUnsafeBytes { Data($0) }
        let toResponder = SymmetricKey(data: bytes.prefix(32)), toInitiator = SymmetricKey(data: bytes.suffix(32))
        return role == .initiator ? LinkCipher(sendKey: toResponder, receiveKey: toInitiator)
            : LinkCipher(sendKey: toInitiator, receiveKey: toResponder)
    }
}

/// One connection's two directions: sealing with a counter nonce, opening only the next counter.
struct LinkCipher {
    let sendKey: SymmetricKey
    let receiveKey: SymmetricKey
    private(set) var sent: UInt64 = 0
    private(set) var received: UInt64 = 0

    init(sendKey: SymmetricKey, receiveKey: SymmetricKey) {
        self.sendKey = sendKey
        self.receiveKey = receiveKey
    }

    static func nonce(_ counter: UInt64) -> Data {
        Data(repeating: 0, count: 4) + withUnsafeBytes(of: counter.bigEndian) { Data($0) }
    }

    mutating func seal(_ plaintext: Data) throws -> Data {
        let box = try ChaChaPoly.seal(plaintext, using: sendKey, nonce: ChaChaPoly.Nonce(data: Self.nonce(sent)))
        sent += 1
        return box.combined
    }

    /// The next frame from the peer, or an error: nothing is accepted out of order.
    mutating func open(_ frame: Data) throws -> Data {
        let frame = Data(frame)
        guard frame.count >= 12 + 16 else { throw LinkError.malformed }
        guard frame.prefix(12) == Self.nonce(received) else { throw LinkError.replay }
        guard let box = try? ChaChaPoly.SealedBox(combined: frame),
              let plaintext = try? ChaChaPoly.open(box, using: receiveKey) else { throw LinkError.authentication }
        received += 1
        return plaintext
    }
}
