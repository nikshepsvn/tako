import XCTest
@testable import Tako

/// `npx -y pkg@x.y.z` runs the copy npx already downloaded, with node, and only then.
final class NpxCacheTests: XCTestCase {
    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("npx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func makeCache(name: String, version: String, bin: Any) throws -> URL {
        let cache = try temporaryFolder()
        let package = cache.appendingPathComponent("abc123/node_modules/\(name)")
        try FileManager.default.createDirectory(at: package.appendingPathComponent("build"), withIntermediateDirectories: true)
        let manifest = try JSONSerialization.data(withJSONObject: ["name": name, "version": version, "bin": bin])
        try manifest.write(to: package.appendingPathComponent("package.json"))
        try Data("// server".utf8).write(to: package.appendingPathComponent("build/index.js"))
        return cache
    }

    func testPinnedNpxRunsTheCachedCopyWithNode() throws {
        let cache = try makeCache(name: "@acme/tool-mcp", version: "1.4.0", bin: ["tool-mcp": "build/index.js"])
        let command = NpxCache.directCommand(["npx", "-y", "@acme/tool-mcp@1.4.0", "--port", "3"], cache: cache)
        XCTAssertEqual(command?.first, "node")
        XCTAssertTrue(command?[1].hasSuffix("node_modules/@acme/tool-mcp/build/index.js") == true)
        XCTAssertEqual(Array(command?.dropFirst(2) ?? []), ["--port", "3"])
    }

    func testNpxIsKeptWhenTheVersionCouldHaveMovedOrIsMissing() throws {
        let cache = try makeCache(name: "tool", version: "2.0.0", bin: "build/index.js")
        XCTAssertNotNil(NpxCache.directCommand(["/opt/homebrew/bin/npx", "--yes", "tool@2.0.0"], cache: cache))
        XCTAssertNil(NpxCache.directCommand(["npx", "-y", "tool@latest"], cache: cache))
        XCTAssertNil(NpxCache.directCommand(["npx", "-y", "tool"], cache: cache))
        XCTAssertNil(NpxCache.directCommand(["npx", "-y", "tool@^2.0.0"], cache: cache))
        XCTAssertNil(NpxCache.directCommand(["npx", "-y", "tool@2.0.1"], cache: cache))
        XCTAssertNil(NpxCache.directCommand(["npx", "-p", "other", "tool@2.0.0"], cache: cache))
        XCTAssertNil(NpxCache.directCommand(["uvx", "tool@2.0.0"], cache: cache))
    }
}
