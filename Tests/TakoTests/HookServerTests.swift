import Darwin
import XCTest
@testable import Tako

/// The hook listener under slow and partial clients: what used to come back as HTTP 400.
final class HookServerTests: XCTestCase {
    private func request(session: String, body: String) -> Data {
        let token = HookServer.token(for: session)
        return Data("POST /hook/claude HTTP/1.1\r\nHost: 127.0.0.1\r\nX-HT-Session: \(session)\r\nAuthorization: Bearer \(token)\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8)
    }

    /// Sends `chunks` with `gap` seconds between them over a raw socket; returns the status line.
    private func send(_ chunks: [Data], gap: TimeInterval, port: UInt16) throws -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = port.bigEndian
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(connected, 0)
        for (index, chunk) in chunks.enumerated() {
            if index > 0 { Thread.sleep(forTimeInterval: gap) }
            _ = chunk.withUnsafeBytes { write(fd, $0.baseAddress, chunk.count) }
        }
        var buffer = [UInt8](repeating: 0, count: 512)
        let n = read(fd, &buffer, buffer.count)
        let reply = String(decoding: buffer.prefix(max(n, 0)), as: UTF8.self)
        return reply.components(separatedBy: "\r\n").first ?? ""
    }

    private func server(deadline: TimeInterval = 5, delivered: XCTestExpectation? = nil) throws -> HookServer {
        let server = HookServer(connectionDeadline: deadline) { _, _, _, _ in delivered?.fulfill() }
        try server.start()
        return server
    }

    func testABodyArrivingAfterAPauseIsStillAccepted() throws {
        let delivered = expectation(description: "delivered")
        let server = try server(delivered: delivered)
        defer { server.stop() }
        let raw = request(session: UUID().uuidString, body: #"{"hook_event_name":"PreToolUse"}"#)
        let split = raw.count - 10
        // Longer than the 2 s per-read timeout that used to turn this into a 400.
        let status = try send([raw.prefix(split), raw.suffix(from: split)], gap: 2.2, port: try XCTUnwrap(server.port))
        XCTAssertEqual(status, "HTTP/1.1 200 OK")
        wait(for: [delivered], timeout: 2)
    }

    func testARequestTricklingInSmallPiecesIsReassembled() throws {
        let delivered = expectation(description: "delivered")
        let server = try server(delivered: delivered)
        defer { server.stop() }
        let raw = request(session: UUID().uuidString, body: String(repeating: "x", count: 300))
        let chunks = stride(from: 0, to: raw.count, by: 37).map { raw.subdata(in: $0..<min($0 + 37, raw.count)) }
        XCTAssertEqual(try send(chunks, gap: 0.01, port: try XCTUnwrap(server.port)), "HTTP/1.1 200 OK")
        wait(for: [delivered], timeout: 2)
    }

    func testABodyThatNeverCompletesTimesOutWith408() throws {
        let server = try server(deadline: 0.5)
        defer { server.stop() }
        let raw = request(session: UUID().uuidString, body: String(repeating: "x", count: 100))
        // The headers promise 100 bytes; only half ever come.
        XCTAssertEqual(try send([raw.dropLast(50)], gap: 0, port: try XCTUnwrap(server.port)), "HTTP/1.1 408 Request Timeout")
    }

    func testGarbageIsStillABadRequest() throws {
        let server = try server()
        defer { server.stop() }
        XCTAssertEqual(try send([Data("nonsense\r\n\r\n".utf8)], gap: 0, port: try XCTUnwrap(server.port)), "HTTP/1.1 400 Bad Request")
    }
}
