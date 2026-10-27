import CryptoKit
import Darwin
import Foundation

/// Loopback HTTP/1.1 listener for Claude Code's `"type": "http"` hooks, so a hook event is a POST
/// instead of a new `ht` process. One request per connection. Each request names its session
/// (`X-HT-Session`) and carries that session's token (`Authorization: Bearer`), both read from the
/// agent's own environment; tokens are derived from a secret that exists only in this process,
/// so a token can't be forged for another session. The reply is sent before the payload is
/// parsed: these events carry no decision.
final class HookServer: @unchecked Sendable {
    typealias Handler = @Sendable (_ source: String, _ sessionID: String, _ body: Data, _ sentAt: UInt64) -> Void

    static let path = "/hook/claude"
    private static let maxRequestBytes = 16_000_000
    private static let connectionDeadline: UInt64 = 5_000_000_000
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
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?
    private(set) var port: UInt16?
    private let acceptQueue = DispatchQueue(label: "dev.tako.hooks.accept")
    /// Serial, so events reach the store in the order Claude sent them.
    private let ioQueue = DispatchQueue(label: "dev.tako.hooks.io", qos: .userInitiated)
    /// Connections are read in parallel, so one idle or slow socket can't hold up the rest.
    private let readQueue = DispatchQueue(label: "dev.tako.hooks.read", qos: .userInitiated, attributes: .concurrent)

    init(handler: @escaping Handler) {
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
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        readQueue.async { [weak self] in self?.serve(client) }
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var parsed = HookHTTPRequest.Parse.incomplete
        // A trickling client can't hold its reader past the deadline.
        let deadline = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + Self.connectionDeadline
        var headChecked = false
        while case .incomplete = parsed, data.count <= Self.maxRequestBytes {
            guard clock_gettime_nsec_np(CLOCK_UPTIME_RAW) < deadline else { return reply(client, status: "408 Request Timeout") }
            let n = read(client, &buffer, buffer.count)
            guard n > 0 else { break }
            data.append(contentsOf: buffer[0..<n])
            // Auth comes from the headers, so an unauthorized sender is dropped before its body is read.
            if !headChecked, let head = HookHTTPRequest.parseHead(data) {
                guard Self.authorizedSession(head) != nil else { return reply(client, status: "403 Forbidden") }
                headChecked = true
            }
            parsed = HookHTTPRequest.parse(data)
        }
        guard case .complete(let request) = parsed else { return reply(client, status: "400 Bad Request") }
        guard let session = Self.authorizedSession(request) else { return reply(client, status: "403 Forbidden") }
        // Queued before the reply: Claude sends its next event only once this one is answered,
        // so the serial queue gets them in the order they were sent.
        let handler = self.handler
        let body = request.body
        // Stamped on the serial queue, so stamps rise in the order the store gets them: a slow
        // read finishing late isn't dropped as older than events queued before it.
        ioQueue.async { handler("claude", session, body, clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) }
        reply(client, status: "200 OK")
    }

    private func reply(_ client: Int32, status: String) {
        let head = Data("HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
        _ = head.withUnsafeBytes { write(client, $0.baseAddress, head.count) }
    }
}

/// The parts of an HTTP/1.1 request the hook listener needs. Bodies must have a Content-Length.
struct HookHTTPRequest {
    enum Parse {
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
