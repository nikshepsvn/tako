import Darwin
import Foundation

/// Unix-socket server for `ht`, agent hooks, and the MCP bridge. One JSON request per
/// connection. The caller is identified from the kernel's peer pid before anything else, and the
/// request is handed to the main actor asynchronously; the handler may answer later (a pending
/// approval), so no thread is parked while it waits.
final class ControlServer: @unchecked Sendable {
    typealias Reply = @Sendable (ControlResponse) -> Void
    /// The kernel's peer pid rides along for requests that lease resources per process (`heavy`).
    typealias Handler = @MainActor (ControlRequest, CallerIdentity, pid_t?, @escaping Reply) -> Void
    typealias Identify = @Sendable (pid_t) -> CallerIdentity

    private static let maxRequestBytes = 1_000_000

    private let path: String
    private let handler: Handler
    private let identify: Identify
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?
    private let acceptQueue = DispatchQueue(label: "dev.tako.control.accept")
    private let ioQueue = DispatchQueue(label: "dev.tako.control.io", attributes: .concurrent)

    init(path: String, identify: @escaping Identify, handler: @escaping Handler) {
        self.path = path
        self.identify = identify
        self.handler = handler
    }

    func start() throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { close(fd); throw POSIXError(.EADDRINUSE) }
        // Only this user may connect: sessions can type into terminals through this socket.
        chmod(path, 0o600)
        guard listen(fd, 128) == 0 else { close(fd); throw POSIXError(.EIO) }

        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler { [weak self] in self?.acceptConnection() }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        if listenFD >= 0 { close(listenFD) }
        unlink(path)
    }

    private func acceptConnection() {
        let client = accept(listenFD, nil, nil)
        guard client >= 0 else { return }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        // Read the peer pid immediately, while the peer is certainly alive.
        let peer = peerPID(client)
        ioQueue.async { [weak self] in self?.serve(client, peer: peer) }
    }

    private func serve(_ client: Int32, peer: pid_t?) {
        let caller = peer.map(identify) ?? .unknown
        guard let raw = readRequestLine(fd: client, limit: Self.maxRequestBytes),
              let request = try? JSONDecoder().decode(ControlRequest.self, from: raw) else {
            respond(client, .failure("malformed or oversized request"))
            return
        }
        let handler = self.handler
        // Hook and statusline replies carry nothing: answer now so the agent never waits on main.
        let immediate = request.cmd == .hook || request.cmd == .statusline
        let reply: Reply
        if immediate {
            respond(client, .success())
            reply = { _ in }
        } else {
            reply = { [weak self] response in self?.respond(client, response) }
        }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { handler(request, caller, peer, reply) }
        }
    }

    private func respond(_ client: Int32, _ response: ControlResponse) {
        ioQueue.async {
            defer { close(client) }
            guard var data = try? JSONEncoder().encode(response) else { return }
            data.append(0x0A)
            _ = data.withUnsafeBytes { write(client, $0.baseAddress, data.count) }
        }
    }

    private func peerPID(_ fd: Int32) -> pid_t? {
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0, pid > 0 else { return nil }
        return pid
    }
}

/// Reads one newline-terminated line, or nil when it exceeds `limit` bytes.
private func readRequestLine(fd: Int32, limit: Int) -> Data? {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while data.count <= limit {
        let n = read(fd, &buffer, buffer.count)
        if n <= 0 { return data.isEmpty ? nil : data }
        if let newline = buffer[0..<n].firstIndex(of: 0x0A) {
            data.append(contentsOf: buffer[0..<newline])
            return data
        }
        data.append(contentsOf: buffer[0..<n])
    }
    return nil
}
