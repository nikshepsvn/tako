import AppKit
import Foundation
import Network

/// Tako Link: two Takos on the same network find each other over Bonjour, pair once by comparing
/// a 6-digit code, and then their Sumis exchange encrypted chats, asks and answers (`LinkCrypto`
/// documents the protocol). No server: messages only travel while both apps are open on the LAN.
///
/// Off by default. While off nothing listens or browses, so macOS shows no local-network or
/// firewall prompt. Settings live in `link.json` and the key in `link-key` (0600) under the
/// support folder, not in UserDefaults, so two instances with their own HT_HOME stay apart.
@MainActor
final class TakoLink: ObservableObject {
    static let serviceType = "_tako._tcp"

    struct Peer: Codable, Equatable, Identifiable {
        var name: String
        var publicKey: Data
        var pairedAt: Date

        var fingerprint: String { LinkIdentity.fingerprint(of: publicKey) }
        var id: String { fingerprint }
    }

    /// A Tako advertising on this network right now.
    struct Nearby: Equatable, Identifiable {
        var name: String
        var fingerprint: String
        var endpoint: NWEndpoint

        var id: String { fingerprint }
    }

    struct Settings: Codable, Equatable {
        var enabled = false
        /// Shown to friends; nil uses the macOS user's full name.
        var name: String?
        var peers: [Peer] = []
    }

    /// The pairing on screen, from either side.
    struct Pairing: Equatable {
        enum Phase: Equatable { case connecting, comparing, waitingForPeer, paired, failed(String) }
        var name: String
        var fingerprint: String?
        var code: String?
        var phase: Phase
        /// They asked us.
        var incoming: Bool
    }

    @Published private(set) var settings: Settings
    @Published private(set) var nearby: [Nearby] = []
    @Published private(set) var pairing: Pairing?
    /// The listener's state in a few words, for Settings.
    @Published private(set) var status = "Off"
    /// Sumi's outgoing messages waiting for the user's Send, Edit or Deny.
    @Published var approvals: [LinkApproval] = []
    /// Recent messages both ways, for the Sumi dock. Memory only.
    @Published var inbox: [LinkInboxItem] = []
    /// Peer messages that arrived while Sumi wasn't running; delivered once it is.
    var undelivered: [String] = []
    /// Asks from peers that Sumi may answer, by a request id Tako made here (never the peer's).
    var openAsks: [String: LinkOpenAsk] = [:]
    /// Asks Sumi sent: request id → the peer asked. Only these may come back as answers.
    var sentAsks: [String: String] = [:]
    var incomingLimit = LinkRateLimit(limit: 30, window: 60)
    var pairLimit = LinkRateLimit(limit: 3, window: 60)

    let identity: LinkIdentity
    private let directory: URL?
    private var listener: NWListener?
    private var browser: NWBrowser?
    /// Every live connection, and the authenticated ones by peer fingerprint.
    private var connections: [ObjectIdentifier: LinkConnection] = [:]
    private var open: [String: LinkConnection] = [:]
    private var pairingConnection: LinkConnection?

    /// A paired peer's message passed every check.
    var onMessage: ((Peer, LinkMessage) -> Void)?
    /// Someone nearby asked to pair; the user should look.
    var onPairingRequest: ((String) -> Void)?
    /// Tests deliver here instead of the network: nil means sent, else why not.
    var transportOverride: ((Peer, LinkMessage) -> String?)?

    /// `directory` nil (tests, previews) keeps everything in memory and never touches the network.
    init(directory: URL?) {
        self.directory = directory
        identity = directory.map { LinkIdentity.load(from: $0.appendingPathComponent("link-key")) } ?? .generate()
        settings = directory.flatMap { Self.loadSettings(from: $0.appendingPathComponent("link.json")) } ?? Settings()
    }

    var displayName: String {
        LinkChannel.cleanName(settings.name ?? NSFullUserName(), fallback: NSUserName())
    }

    var peers: [Peer] { settings.peers }

    /// The paired peer with exactly this name (ignoring case) or full fingerprint. No prefixes or
    /// guesses: a message must never reach a different friend than the one named.
    func peer(named name: String) -> Peer? {
        let wanted = name.trimmingCharacters(in: .whitespaces).lowercased()
        return peers.first { $0.name.lowercased() == wanted || $0.fingerprint == wanted }
    }

    func peer(fingerprint: String) -> Peer? { peers.first { $0.fingerprint == fingerprint } }

    func isOnline(_ peer: Peer) -> Bool {
        nearby.contains { $0.fingerprint == peer.fingerprint } || open[peer.fingerprint]?.channel.isOpen == true
    }

    // MARK: - Settings

    func setEnabled(_ on: Bool) {
        settings.enabled = on
        save()
        on ? start() : stop()
    }

    func setName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.name = trimmed.isEmpty ? nil : LinkChannel.cleanName(trimmed)
        save()
        // The Bonjour name and TXT record carry it.
        if listener != nil { stop(); start() }
    }

    func unpair(_ peer: Peer) {
        settings.peers.removeAll { $0.publicKey == peer.publicKey }
        save()
        open.removeValue(forKey: peer.fingerprint)?.channel.close("unpaired")
        openAsks = openAsks.filter { $0.value.fingerprint != peer.fingerprint }
        sentAsks = sentAsks.filter { $0.value != peer.fingerprint }
        EventLog.record("link", "unpaired \(peer.name)", fields: ["peer": peer.name, "fingerprint": peer.fingerprint])
    }

    /// Stores a peer both users confirmed. A known key keeps its place and takes the new name.
    func addPeer(name: String, key: Data, at date: Date = Date()) {
        let peer = Peer(name: name, publicKey: key, pairedAt: date)
        if let index = settings.peers.firstIndex(where: { $0.publicKey == key }) {
            settings.peers[index] = peer
        } else {
            settings.peers.append(peer)
        }
        save()
        EventLog.record("link", "paired with \(name)", fields: ["peer": name, "fingerprint": peer.fingerprint])
    }

    private static func loadSettings(from url: URL) -> Settings? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Settings.self, from: data)
    }

    private func save() {
        guard let directory else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(settings) else { return }
        let url = directory.appendingPathComponent("link.json")
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // MARK: - Listening and browsing

    /// Advertises and browses while Link is on. Safe to call again.
    func start() {
        guard settings.enabled, directory != nil, listener == nil else { return }
        let parameters = NWParameters.tcp
        guard let listener = try? NWListener(using: parameters) else {
            status = "Couldn't listen"
            return
        }
        let txt = NWTXTRecord(["name": displayName, "fp": identity.fingerprint, "v": "\(LinkCrypto.version)"])
        listener.service = NWListener.Service(name: displayName, type: Self.serviceType, domain: nil, txtRecord: txt)
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.listenerChanged(state) }
        }
        self.listener = listener
        listener.start(queue: .main)

        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated { self?.update(results) }
        }
        self.browser = browser
        browser.start(queue: .main)
        status = "Starting…"
    }

    func stop() {
        listener?.cancel()
        listener = nil
        browser?.cancel()
        browser = nil
        nearby = []
        connections.values.forEach { $0.channel.close("Link turned off") }
        connections = [:]
        open = [:]
        pairingConnection = nil
        if pairing?.phase != .paired { pairing = nil }
        status = "Off"
    }

    var port: UInt16? { listener?.port?.rawValue }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready: status = "On"
        case .waiting(let error): status = "Waiting: \(error.localizedDescription)"
        case .failed(let error):
            status = "Failed: \(error.localizedDescription)"
            listener?.cancel()
            listener = nil
        case .cancelled: if settings.enabled { status = "Stopped" }
        default: break
        }
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        nearby = results.compactMap { result -> Nearby? in
            guard case .bonjour(let txt) = result.metadata, let fingerprint = txt["fp"], fingerprint != identity.fingerprint else { return nil }
            var name = txt["name"]
            if name == nil, case .service(let service, _, _, _) = result.endpoint { name = service }
            return Nearby(name: LinkChannel.cleanName(name), fingerprint: fingerprint, endpoint: result.endpoint)
        }
        .reduce(into: [Nearby]()) { list, item in if !list.contains(where: { $0.fingerprint == item.fingerprint }) { list.append(item) } }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        let link = LinkConnection(connection: connection, channel: makeChannel(role: .responder))
        adopt(link)
    }

    private func dial(_ endpoint: NWEndpoint) -> LinkConnection {
        let link = LinkConnection(connection: NWConnection(to: endpoint, using: .tcp), channel: makeChannel(role: .initiator))
        adopt(link)
        return link
    }

    private func makeChannel(role: LinkChannel.Role) -> LinkChannel {
        let channel = LinkChannel(identity: identity, role: role, localName: displayName)
        channel.isPaired = { [weak self] key in self?.settings.peers.contains { $0.publicKey == key } ?? false }
        channel.allowsPairRequest = { [weak self] _ in
            guard let self else { return false }
            return !self.isPairingBusy && self.pairLimit.allow("pair")
        }
        return channel
    }

    private func adopt(_ link: LinkConnection) {
        connections[ObjectIdentifier(link)] = link
        link.channel.onEvent = { [weak self, weak link] event in
            guard let self, let link else { return }
            self.handle(event, on: link)
        }
        link.start()
    }

    private func handle(_ event: LinkChannel.Event, on link: LinkConnection) {
        switch event {
        case .open(let key):
            let fingerprint = LinkIdentity.fingerprint(of: key)
            open[fingerprint] = link
            link.flush()
        case .message(let message):
            guard let key = link.channel.peerKey, let peer = settings.peers.first(where: { $0.publicKey == key }) else {
                return link.channel.close("\(LinkError.unknownKey)")
            }
            receive(message, from: peer)
        case .pairRequested(let name, let key):
            pairingConnection = link
            pairing = Pairing(name: name, fingerprint: LinkIdentity.fingerprint(of: key), phase: .connecting, incoming: true)
        case .pairCode(let name, let key, let code):
            pairing = Pairing(name: name, fingerprint: LinkIdentity.fingerprint(of: key), code: code, phase: .comparing,
                              incoming: pairing?.incoming ?? false)
            if pairing?.incoming == true { onPairingRequest?(name) }
        case .paired(let name, let key):
            addPeer(name: name, key: key)
            pairing?.phase = .paired
            pairing?.name = name
            clearPairing(after: 4)
        case .closed(let reason):
            connections[ObjectIdentifier(link)] = nil
            if let key = link.channel.peerKey, open[LinkIdentity.fingerprint(of: key)] === link {
                open[LinkIdentity.fingerprint(of: key)] = nil
            }
            link.fail(reason)
            if pairingConnection === link {
                pairingConnection = nil
                if let current = pairing, current.phase != .paired {
                    pairing?.phase = .failed(reason)
                    clearPairing(after: 8)
                }
            }
            link.cancel()
        }
    }

    private func clearPairing(after seconds: TimeInterval) {
        let shown = pairing
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            if self?.pairing == shown { self?.pairing = nil }
        }
    }

    // MARK: - Messages

    /// Checks a paired peer's message against the per-peer rate limit, logs it, and hands it on.
    func receive(_ message: LinkMessage, from peer: Peer, now: Date = Date()) {
        guard message.kind != .ready else { return }
        let bytes = message.text?.utf8.count ?? 0
        guard bytes <= LinkLimits.maxText else {
            audit("dropped", peer: peer, kind: message.kind, bytes: bytes, note: "too large")
            return
        }
        guard message.hasValidIDs else {
            audit("dropped", peer: peer, kind: message.kind, bytes: bytes, note: "malformed id")
            return
        }
        guard incomingLimit.allow(peer.fingerprint, now: now) else {
            audit("dropped", peer: peer, kind: message.kind, bytes: bytes, note: "rate limited")
            return
        }
        audit("received", peer: peer, kind: message.kind, bytes: bytes)
        onMessage?(peer, message)
    }

    /// Sends over an open session, dialing one first if needed. `completion` gets nil once the
    /// frame is handed to the socket, or why it couldn't go.
    func send(_ message: LinkMessage, to peer: Peer, completion: @escaping (String?) -> Void) {
        let finish: (String?) -> Void = { [weak self] error in
            let bytes = message.text?.utf8.count ?? 0
            self?.audit(error == nil ? "sent" : "send failed", peer: peer, kind: message.kind, bytes: bytes, note: error)
            completion(error)
        }
        if let transportOverride { return finish(transportOverride(peer, message)) }
        guard settings.enabled else { return finish("Tako Link is off") }
        if let link = open[peer.fingerprint], link.channel.isOpen, !link.channel.isClosed {
            return link.enqueue(message, finish)
        }
        guard let endpoint = nearby.first(where: { $0.fingerprint == peer.fingerprint })?.endpoint else {
            return finish("\(peer.name) isn't online: their Tako must be open with Link on, on this network")
        }
        let link = dial(endpoint)
        link.enqueue(message, finish)
        link.channel.startSession(with: peer.publicKey)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak link] in
            guard let link, !link.channel.isOpen else { return }
            link.channel.close("couldn't reach \(peer.name) in 10 s")
        }
    }

    /// Every message in and out is logged with its peer, kind and size, never its text.
    private func audit(_ what: String, peer: Peer, kind: LinkMessage.Kind, bytes: Int, note: String? = nil) {
        var fields: [String: Any] = ["peer": peer.name, "fingerprint": peer.fingerprint, "message": kind.rawValue, "bytes": bytes]
        if let note { fields["note"] = note }
        EventLog.record("link", "\(what) \(kind.rawValue) (\(bytes) B) \(what == "sent" ? "to" : "from") \(peer.name)", fields: fields)
    }

    // MARK: - Pairing

    func pair(with nearby: Nearby) {
        guard !isPairingBusy else { return }
        let link = dial(nearby.endpoint)
        pairingConnection = link
        pairing = Pairing(name: nearby.name, fingerprint: nearby.fingerprint, phase: .connecting, incoming: false)
        link.channel.startPairing()
        let shown = pairing
        // An unanswered request doesn't hold the slot forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self, weak link] in
            guard let self, self.pairing == shown || self.pairing?.phase == .comparing, self.pairingConnection === link else { return }
            link?.channel.close("pairing timed out")
        }
    }

    /// One pairing at a time; a finished or failed one no longer counts.
    var isPairingBusy: Bool {
        switch pairing?.phase {
        case nil, .paired, .failed: return false
        default: return true
        }
    }

    func confirmPairing() {
        guard let link = pairingConnection, pairing?.phase == .comparing else { return }
        pairing?.phase = .waitingForPeer
        link.channel.confirmPairing()
    }

    func cancelPairing() {
        if let link = pairingConnection {
            link.channel.cancelPairing()
        }
        pairingConnection = nil
        pairing = nil
    }
}

/// One TCP connection: Network.framework below, `LinkChannel` above, and the messages waiting
/// for the handshake to finish.
@MainActor
final class LinkConnection {
    let connection: NWConnection
    let channel: LinkChannel
    private var framer = LinkFramer()
    private var pending: [(message: LinkMessage, done: (String?) -> Void)] = []

    init(connection: NWConnection, channel: LinkChannel) {
        self.connection = connection
        self.channel = channel
    }

    func start() {
        channel.write = { [weak self] payload in
            self?.connection.send(content: LinkFramer.frame(payload), completion: .contentProcessed { _ in })
        }
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .failed(let error): self?.channel.close(error.localizedDescription)
                case .waiting(let error): self?.channel.close(error.localizedDescription)
                default: break
                }
            }
        }
        connection.start(queue: .main)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let data, !data.isEmpty {
                    do {
                        for frame in try self.framer.append(data) { self.channel.receive(frame) }
                    } catch {
                        self.channel.close("\(error)")
                    }
                }
                if isComplete || error != nil {
                    self.channel.close("connection ended")
                } else if !self.channel.isClosed {
                    self.receive()
                }
            }
        }
    }

    func enqueue(_ message: LinkMessage, _ done: @escaping (String?) -> Void) {
        pending.append((message, done))
        if channel.isOpen { flush() }
    }

    func flush() {
        let waiting = pending
        pending = []
        for item in waiting {
            do {
                try channel.send(item.message)
                item.done(nil)
            } catch {
                item.done("\(error)")
            }
        }
    }

    func fail(_ reason: String) {
        let waiting = pending
        pending = []
        waiting.forEach { $0.done(reason) }
    }

    /// After a moment, so a final `bye` reaches the peer first.
    func cancel() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [connection] in connection.cancel() }
    }
}

/// A peer's ask Sumi may answer: who asked, and the id their Tako gave it.
struct LinkOpenAsk: Equatable {
    var fingerprint: String
    var remoteID: String
}

/// An outgoing message Sumi wrote in a turn that wasn't the user's: it waits for their Send,
/// Edit or Deny.
struct LinkApproval: Identifiable, Equatable {
    let id: String
    var peer: TakoLink.Peer
    var message: LinkMessage
    var createdAt = Date()
}

/// A message on the Link, for the Sumi dock's conversation view.
struct LinkInboxItem: Identifiable, Equatable {
    let id: String
    var peerName: String
    var kind: LinkMessage.Kind
    var text: String
    var requestID: String?
    var incoming: Bool
    var at = Date()
}

/// At most `limit` events per key in any `window` seconds.
struct LinkRateLimit {
    let limit: Int
    let window: TimeInterval
    private var hits: [String: [Date]] = [:]

    init(limit: Int, window: TimeInterval) {
        self.limit = limit
        self.window = window
    }

    mutating func allow(_ key: String, now: Date = Date()) -> Bool {
        var recent = (hits[key] ?? []).filter { now.timeIntervalSince($0) < window }
        guard recent.count < limit else {
            hits[key] = recent
            return false
        }
        recent.append(now)
        hits[key] = recent
        return true
    }
}
