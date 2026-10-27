import CryptoKit
import Darwin
import Foundation

/// Loopback HTTP/1.1 listener for Claude Code's `"type": "http"` hooks, so a hook event is a POST
/// instead of a new `ht` process. One request per connection. Each request names its session
/// (`X-HT-Session`) and carries that session's token (`Authorization: Bearer`), both read from the
/// agent's own environment; tokens are derived from a secret that exists only in this process,
/// so a token can't be forged for another session. The reply is sent before the store sees the
/// event: these events carry no decision. The one thing a reply may carry is the advisor's
/// heads-up for an edit inside another agent's file claim (ClaimAdvisor).
final class HookServer: @unchecked Sendable {
    typealias Handler = @Sendable (_ source: String, _ sessionID: String, _ body: Data, _ sentAt: UInt64) -> Void
    /// A JSON body for the reply, or nil for an empty one. Runs on the connection's thread, so
    /// it must answer from memory.
    typealias Advisor = @Sendable (_ sessionID: String, _ body: Data) -> Data?

    static let path = "/hook/claude"
    private static let maxRequestBytes = 16_000_000
    private static let secret = SymmetricKey(size: .bits256)

    /// The token a session's agent sends; set as HT_HOOK_TOKEN in its environment.
    static func token(for sessionID: String) -> String {
        HMAC<SHA256>.authenticationCode(for: Data(sessionID.utf8), using: secret)
            .map { String(format: "%02x", $0) }.joined()
    }

    /// The session a request is for, when it is a hook POST with that session's token.
    static func authorizedSession(_ request: HookHTTPRequest) -> String? {
        guard request.method == "POST", request.path == path,
              let session = request.headers["x-ht-session"], UUID(uuidString: session) != nil,
              let auth = request.headers["authorization"], auth.hasPrefix("Bearer ") else { return nil }
        let given = Array(auth.dropFirst("Bearer ".count).utf8), expected = Array(token(for: session).utf8)
        guard given.count == expected.count else { return nil }
        return zip(given, expected).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0 ? session : nil
    }

    private let handler: Handler
    private let advisor: Advisor?
    /// How long one connection may take to deliver its whole request.
    private let connectionDeadline: UInt64
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?
    private(set) var port: UInt16?
    private let acceptQueue = DispatchQueue(label: "dev.tako.hooks.accept")
    /// Serial, so events reach the store in the order Claude sent them.
    private let ioQueue = DispatchQueue(label: "dev.tako.hooks.io", qos: .userInitiated)
    /// Connections are read in parallel, so one idle or slow socket can't hold up the rest.
    private let readQueue = DispatchQueue(label: "dev.tako.hooks.read", qos: .userInitiated, attributes: .concurrent)

    init(connectionDeadline: TimeInterval = 5, advisor: Advisor? = nil, handler: @escaping Handler) {
        self.connectionDeadline = UInt64(connectionDeadline * 1_000_000_000)
        self.advisor = advisor
        self.handler = handler
    }

    /// Binds 127.0.0.1 on an ephemeral port.
    func start() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) == 0 && getsockname(fd, $0, &size) == 0 }
        }
        guard bound, listen(fd, 128) == 0 else { close(fd); throw POSIXError(.EADDRINUSE) }
        port = UInt16(bigEndian: addr.sin_port)
        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler { [weak self] in self?.acceptConnection() }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        if listenFD >= 0 { close(listenFD) }
    }

    private func acceptConnection() {
        let client = accept(listenFD, nil, nil)
        guard client >= 0 else { return }
        var noSigPipe: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        readQueue.async { [weak self] in self?.serve(client) }
    }

    /// How reading a request ended.
    enum ReadOutcome: Equatable {
        case request(HookHTTPRequest)
        case forbidden, malformed, tooLarge, timedOut, closedEarly

        var status: String {
            switch self {
            case .request: return "200 OK"
            case .forbidden: return "403 Forbidden"
            case .malformed, .closedEarly: return "400 Bad Request"
            case .tooLarge: return "413 Content Too Large"
            case .timedOut: return "408 Request Timeout"
            }
        }
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        let outcome = Self.readRequest(client, deadline: clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + connectionDeadline)
        guard case .request(let request) = outcome else {
            // A dropped hook leaves a card's status stale; keep a trace of each one.
            EventLog.record("hook", "answered \(outcome.status)", fields: ["outcome": "\(outcome)"])
            return reply(client, status: outcome.status)
        }
        guard let session = Self.authorizedSession(request) else { return reply(client, status: ReadOutcome.forbidden.status) }
        // Queued before the reply: Claude sends its next event only once this one is answered,
        // so the serial queue gets them in the order they were sent.
        let handler = self.handler
        let body = request.body
        // Stamped on the serial queue, so stamps rise in the order the store gets them: a slow
        // read finishing late isn't dropped as older than events queued before it.
        ioQueue.async { handler("claude", session, body, clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) }
        reply(client, status: "200 OK", body: advisor?(session, body))
    }

    /// Reads one request until its Content-Length has arrived or `deadline` (uptime ns) passes.
    /// Waits with poll() for the time left rather than a per-read socket timeout: under load
    /// (180 agents) a 2 s SO_RCVTIMEO made read() return EAGAIN mid-request, which used to end
    /// the loop and answer a perfectly good hook with 400, leaving card status stale.
    static func readRequest(_ client: Int32, deadline: UInt64) -> ReadOutcome {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var headChecked = false
        while true {
            switch HookHTTPRequest.parse(data) {
            case .complete(let request): return .request(request)
            case .invalid: return .malformed
            case .incomplete: break
            }
            guard data.count <= maxRequestBytes else { return .tooLarge }
            let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            guard now < deadline else { return .timedOut }
            var poller = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, Int32(min((deadline - now) / 1_000_000 + 1, UInt64(Int32.max))))
            if ready < 0, errno != EINTR { return .closedEarly }
            guard ready > 0 else { continue }
            let n = read(client, &buffer, buffer.count)
            if n < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { continue }
            guard n > 0 else { return .closedEarly }
            data.append(contentsOf: buffer[0..<n])
            // Auth comes from the headers, so an unauthorized sender is dropped before its body is read.
            if !headChecked, let head = HookHTTPRequest.parseHead(data) {
                guard authorizedSession(head) != nil else { return .forbidden }
                headChecked = true
            }
        }
    }

    private func reply(_ client: Int32, status: String, body: Data? = nil) {
        let type = body == nil ? "" : "Content-Type: application/json\r\n"
        var message = Data("HTTP/1.1 \(status)\r\n\(type)Content-Length: \(body?.count ?? 0)\r\nConnection: close\r\n\r\n".utf8)
        if let body { message.append(body) }
        _ = message.withUnsafeBytes { write(client, $0.baseAddress, message.count) }
    }
}

/// The parts of an HTTP/1.1 request the hook listener needs. Bodies must have a Content-Length.
struct HookHTTPRequest: Equatable {
    enum Parse: Equatable {
        case incomplete, invalid, complete(HookHTTPRequest)
    }

    let method: String
    let path: String
    /// Names lowercased.
    let headers: [String: String]
    let body: Data

    /// The request line and headers as soon as they have all arrived, with an empty body.
    static func parseHead(_ data: Data) -> HookHTTPRequest? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)),
              case .complete(let head) = parse(Data(data[data.startIndex..<end.lowerBound]) + Data("\r\n\r\n".utf8), bodyOptional: true)
        else { return nil }
        return head
    }

    static func parse(_ data: Data, bodyOptional: Bool = false) -> Parse {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return .incomplete }
        let lines = String(decoding: data[data.startIndex..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let start = lines[0].split(separator: " ")
        guard start.count == 3, start[2].hasPrefix("HTTP/1.") else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil else { return .invalid }
        guard let length = Int(headers["content-length"] ?? "0"), length >= 0 else { return .invalid }
        let body = data[end.upperBound...]
        guard bodyOptional || body.count >= length else { return .incomplete }
        return .complete(HookHTTPRequest(method: String(start[0]), path: String(start[1]), headers: headers, body: Data(body.prefix(length))))
    }
}
