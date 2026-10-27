import XCTest
@testable import Tako

final class ProxyFixTests: XCTestCase {
    func testRequestKeyDistinguishesIntegerAndStringIds() throws {
        XCTAssertNotEqual(mcpRequestKey(1), mcpRequestKey("1"))
        XCTAssertEqual(mcpRequestKey(1), mcpRequestKey(1))
        XCTAssertEqual(mcpRequestKey("a"), mcpRequestKey("a"))
        // Ids as JSONSerialization decodes them.
        let ids = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(#"{"a":1,"b":"1"}"#.utf8)) as? [String: Any])
        XCTAssertNotEqual(mcpRequestKey(try XCTUnwrap(ids["a"])), mcpRequestKey(try XCTUnwrap(ids["b"])))
    }
}
