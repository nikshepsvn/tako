import Foundation
import XCTest
@testable import Tako

final class ProjectActionTests: XCTestCase {
    private var root: String!

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "kuronami-actions-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    private func write(_ name: String, _ text: String) throws {
        try text.write(toFile: (root as NSString).appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func testPackageScriptsUseTheProjectsPackageManager() throws {
        try write("package.json", #"{"scripts":{"build":"tsc","dev":"vite","test":"vitest","postinstall":"x"}}"#)
        try write("pnpm-lock.yaml", "")
        let actions = ProjectAction.detect(at: root)
        XCTAssertEqual(actions.map(\.command), ["pnpm dev", "pnpm test", "pnpm build"])
        XCTAssertTrue(actions[0].isServer)
        XCTAssertFalse(actions[1].isServer)
        XCTAssertEqual(actions[1].symbol, "checkmark.diamond")
    }

    func testNpmIsTheFallbackRunner() throws {
        try write("package.json", #"{"scripts":{"lint":"eslint ."}}"#)
        XCTAssertEqual(ProjectAction.detect(at: root).map(\.command), ["npm run lint"])
    }

    func testCargoAndSwift() throws {
        try write("Cargo.toml", "[package]")
        XCTAssertEqual(ProjectAction.detect(at: root).first?.command, "cargo build")
        try FileManager.default.removeItem(atPath: (root as NSString).appendingPathComponent("Cargo.toml"))
        try write("Package.swift", "// swift-tools-version:5.9")
        XCTAssertEqual(ProjectAction.detect(at: root).map(\.command), ["swift build", "swift test"])
    }

    func testMakefileTargets() throws {
        try write("Makefile", "build: deps\n\tcc main.c\n.PHONY: build\ntest:\n\t./run\nVAR := 1\n")
        XCTAssertEqual(ProjectAction.detect(at: root).map(\.command), ["make build", "make test"])
    }

    func testNothingToDetect() {
        XCTAssertTrue(ProjectAction.detect(at: root).isEmpty)
    }

    func testDeclaredActionsDecode() throws {
        let json = #"{"name":"Storybook","command":"pnpm storybook","icon":"book.closed","server":true}"#
        let action = try JSONDecoder().decode(ProjectAction.self, from: Data(json.utf8))
        XCTAssertEqual(action.symbol, "book.closed")
        XCTAssertTrue(action.isServer)
    }
}
