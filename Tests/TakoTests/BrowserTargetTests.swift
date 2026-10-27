import XCTest
@testable import Tako

final class BrowserTargetTests: XCTestCase {
    private var directory: String!

    override func setUpWithError() throws {
        directory = NSTemporaryDirectory() + "browser-target-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory + "/out", withIntermediateDirectories: true)
        try "<h1>hi</h1>".write(toFile: directory + "/out/report.html", atomically: true, encoding: .utf8)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: directory)
    }

    func testAbsoluteAndRelativePathsBecomeFileURLs() {
        let absolute = BrowserTarget.fileURL(directory + "/out/report.html", cwd: "/")
        XCTAssertEqual(absolute?.scheme, "file")
        XCTAssertEqual(absolute?.lastPathComponent, "report.html")
        XCTAssertEqual(BrowserTarget.fileURL("out/report.html", cwd: directory)?.lastPathComponent, "report.html")
        XCTAssertEqual(BrowserTarget.fileURL("./out/../out/report.html", cwd: directory)?.lastPathComponent, "report.html")
    }

    func testMissingFilesAndDirectoriesAreNotFiles() {
        XCTAssertNil(BrowserTarget.fileURL("out/nope.html", cwd: directory))
        XCTAssertNil(BrowserTarget.fileURL("out", cwd: directory))
        XCTAssertNil(BrowserTarget.fileURL("", cwd: directory))
    }

    func testWebAddressesPassThrough() {
        XCTAssertNil(BrowserTarget.fileURL("https://example.com/a.html", cwd: directory))
        XCTAssertEqual(BrowserTarget.address("  localhost:3000 ", cwd: directory), "localhost:3000")
        XCTAssertEqual(BrowserTarget.address("https://example.com", cwd: directory), "https://example.com")
    }

    func testAddressForExistingFileIsFileURLString() {
        XCTAssertTrue(BrowserTarget.address("out/report.html", cwd: directory).hasPrefix("file://"))
    }

    func testOnlyPagesAreAllowed() {
        XCTAssertTrue(BrowserTarget.isAllowed(URL(string: "https://a.dev")!))
        XCTAssertTrue(BrowserTarget.isAllowed(URL(string: "file:///tmp/a.html")!))
        XCTAssertFalse(BrowserTarget.isAllowed(URL(string: "javascript:alert(1)")!))
        XCTAssertFalse(BrowserTarget.isAllowed(URL(string: "data:text/html,hi")!))
    }

    func testBrowserRequestCarriesTheURL() throws {
        var request = ControlRequest(cmd: .browser)
        request.url = "file:///tmp/a.html"
        let decoded = try JSONDecoder().decode(ControlRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(decoded.url, "file:///tmp/a.html")
    }
}
