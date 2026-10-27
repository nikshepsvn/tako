import XCTest
@testable import Tako

final class IPCFixTests: XCTestCase {
    func testHeadParsesBeforeBodyArrives() throws {
        let raw = Data("POST /hook HTTP/1.1\r\nContent-Length: 100\r\nX-HT-Session: abc\r\n\r\npartial".utf8)
        let head = try XCTUnwrap(HookHTTPRequest.parseHead(raw))
        XCTAssertEqual(head.method, "POST")
        XCTAssertEqual(head.headers["x-ht-session"], "abc")
        // The full parse still waits for the whole body.
        guard case .incomplete = HookHTTPRequest.parse(raw) else { return XCTFail("body should be incomplete") }
    }

    func testHeadWaitsForTheBlankLine() {
        XCTAssertNil(HookHTTPRequest.parseHead(Data("POST /hook HTTP/1.1\r\nContent-Length: 5\r\n".utf8)))
    }
}
