import XCTest
@testable import Tako

/// The move from the pre-rename names (~/.hyperterm, ~/Library/Caches/Hyperterm/cef) to Tako's,
/// and how the app and `ht` find the data folder before and after it. Every case runs in a
/// temporary home, never the user's.
final class DataDirectoryMigrationTests: XCTestCase {
    private var home: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        home = fm.temporaryDirectory.appendingPathComponent("tako-migration-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.path)
        try? fm.removeItem(at: home)
    }

    private var legacy: URL { home.appendingPathComponent(".hyperterm") }
    private var current: URL { home.appendingPathComponent(".tako") }

    private func isSymlink(_ url: URL) -> Bool {
        (try? fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    private func resolved() -> String {
        ControlPaths.resolveSupportDirectory(home: home, environment: [:]).lastPathComponent
    }

    // MARK: - Moving

    func testFreshInstallHasNothingToMove() {
        XCTAssertEqual(DataDirectoryMigration.migrateSupportDirectory(home: home), .nothingToMove)
        XCTAssertFalse(fm.fileExists(atPath: legacy.path))
        XCTAssertFalse(fm.fileExists(atPath: current.path))
        XCTAssertEqual(resolved(), ".tako")
    }

    func testMovesTheFolderAndLeavesALinkBehind() throws {
        try fm.createDirectory(at: legacy.appendingPathComponent("worktrees/app/alpha"), withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: legacy.appendingPathComponent("sessions.json"))
        let inode = try fm.attributesOfItem(atPath: legacy.path)[.systemFileNumber] as? Int

        XCTAssertEqual(DataDirectoryMigration.migrateSupportDirectory(home: home), .moved)

        XCTAssertTrue(isSymlink(legacy))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: legacy.path), current.path)
        XCTAssertFalse(isSymlink(current))
        // Renamed in place, not copied: the same folder under its new name.
        XCTAssertEqual(try fm.attributesOfItem(atPath: current.path)[.systemFileNumber] as? Int, inode)
        XCTAssertTrue(fm.fileExists(atPath: current.appendingPathComponent("sessions.json").path))
        // Paths saved before the move still reach the data.
        XCTAssertTrue(fm.fileExists(atPath: legacy.appendingPathComponent("worktrees/app/alpha").path))
        XCTAssertEqual(resolved(), ".tako")
    }

    func testSecondRunIsANoOp() throws {
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        XCTAssertEqual(DataDirectoryMigration.migrateSupportDirectory(home: home), .moved)
        XCTAssertEqual(DataDirectoryMigration.migrateSupportDirectory(home: home), .alreadyDone)
        XCTAssertTrue(isSymlink(legacy))
        XCTAssertFalse(isSymlink(current))
    }

    func testBothExistingLeavesBothAlone() throws {
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        try fm.createDirectory(at: current, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: legacy.appendingPathComponent("sessions.json"))

        XCTAssertEqual(DataDirectoryMigration.migrateSupportDirectory(home: home), .bothExist)

        XCTAssertFalse(isSymlink(legacy))
        XCTAssertTrue(fm.fileExists(atPath: legacy.appendingPathComponent("sessions.json").path))
        XCTAssertFalse(fm.fileExists(atPath: current.appendingPathComponent("sessions.json").path))
        XCTAssertEqual(resolved(), ".tako")
    }

    func testFailedMoveLeavesTheOldFolderInPlace() throws {
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: legacy.appendingPathComponent("sessions.json"))
        // A home the rename can't write to.
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: home.path)

        guard case .failed = DataDirectoryMigration.migrateSupportDirectory(home: home) else {
            return XCTFail("expected the move to fail")
        }

        XCTAssertFalse(isSymlink(legacy))
        XCTAssertTrue(fm.fileExists(atPath: legacy.appendingPathComponent("sessions.json").path))
        XCTAssertFalse(fm.fileExists(atPath: current.path))
        // Both the app and ht keep using it.
        XCTAssertEqual(resolved(), ".hyperterm")
    }

    func testAFileAtTheOldPathIsNotMoved() throws {
        try Data("x".utf8).write(to: legacy)
        guard case .failed = DataDirectoryMigration.migrateSupportDirectory(home: home) else {
            return XCTFail("expected a refusal")
        }
        XCTAssertFalse(fm.fileExists(atPath: current.path))
    }

    func testMovesTheBrowserDownloadCache() throws {
        let caches = home.appendingPathComponent("Library/Caches")
        let old = caches.appendingPathComponent("Hyperterm/cef")
        try fm.createDirectory(at: old.appendingPathComponent("cef_binary"), withIntermediateDirectories: true)

        XCTAssertEqual(DataDirectoryMigration.migrateBrowserCache(caches: caches), .moved)

        XCTAssertTrue(fm.fileExists(atPath: caches.appendingPathComponent("Tako/cef/cef_binary").path))
        XCTAssertTrue(isSymlink(old))
        XCTAssertEqual(DataDirectoryMigration.migrateBrowserCache(caches: caches), .alreadyDone)
    }

    func testBrowserCacheAlreadyDownloadedUnderTheNewNameIsKept() throws {
        let caches = home.appendingPathComponent("Library/Caches")
        try fm.createDirectory(at: caches.appendingPathComponent("Hyperterm/cef"), withIntermediateDirectories: true)
        try fm.createDirectory(at: caches.appendingPathComponent("Tako/cef"), withIntermediateDirectories: true)
        XCTAssertEqual(DataDirectoryMigration.migrateBrowserCache(caches: caches), .bothExist)
    }

    func testTestHostNeverMigrates() throws {
        // runAtLaunch reads the real home; under XCTest it must return before touching it.
        DataDirectoryMigration.runAtLaunch(environment: ["XCTestConfigurationFilePath": "/x"])
    }

    // MARK: - Resolving

    func testResolutionPrefersHTHome() {
        let url = ControlPaths.resolveSupportDirectory(home: home, environment: ["HT_HOME": "/tmp/dev"])
        XCTAssertEqual(url.path, "/tmp/dev")
    }

    func testUnmigratedInstallResolvesToTheOldFolder() throws {
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        XCTAssertEqual(resolved(), ".hyperterm")
    }

    func testDanglingOldLinkResolvesToTheNewFolder() throws {
        try fm.createSymbolicLink(atPath: legacy.path, withDestinationPath: current.path)
        XCTAssertEqual(resolved(), ".tako")
    }

    // MARK: - What still names the old folder

    func testProjectConfigPrefersTheNewFileName() throws {
        try Data(#"{"dev":"old"}"#.utf8).write(to: home.appendingPathComponent(".hyperterm.json"))
        XCTAssertEqual(ProjectConfig.load(for: home.path)?.dev, "old")
        try Data(#"{"dev":"new"}"#.utf8).write(to: home.appendingPathComponent(".tako.json"))
        XCTAssertEqual(ProjectConfig.load(for: home.path)?.dev, "new")
    }

    func testWorktreesMadeBeforeTheMoveStillCount() {
        XCTAssertTrue(WorktreeJanitor.isAgentWorktree("/Users/u/.hyperterm/worktrees/app/alpha",
                                                      support: "/Users/u/.tako", legacySupport: "/Users/u/.hyperterm"))
        XCTAssertTrue(WorktreeJanitor.isAgentWorktree("/Users/u/.tako/worktrees/app/alpha",
                                                      support: "/Users/u/.tako", legacySupport: "/Users/u/.hyperterm"))
        XCTAssertFalse(WorktreeJanitor.isAgentWorktree("/Users/u/Code/app",
                                                       support: "/Users/u/.tako", legacySupport: "/Users/u/.hyperterm"))
    }

    func testOldBinFolderOnPATHIsNotAnInstalledCLI() {
        let executables: Set<String> = ["/Users/me/.hyperterm/bin/claude", "/Users/me/.tako/bin/codex"]
        let installed = InstalledAgents.installed([.claude, .codex], path: "/Users/me/.hyperterm/bin:/Users/me/.tako/bin",
                                                  skipping: "/Users/me/.tako/bin", "/Users/me/.hyperterm/bin",
                                                  isExecutable: executables.contains)
        XCTAssertEqual(installed, [])
    }

    /// The wrappers resolve HT_DIR as ControlPaths does and take every Tako bin folder off PATH,
    /// so `claude` in a wrapper never finds the wrapper again through the old folder.
    func testWrapperPreludeFindsTheFolderAndStripsBothBinFolders() throws {
        func run(_ setup: String) throws -> String {
            let script = AgentIntegration.wrapperPrelude + "\nprintf '%s|%s' \"$HT_DIR\" \"$PATH\"\n"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", setup + "\n" + script]
            process.environment = ["HOME": home.path, "PATH": "\(home.path)/.hyperterm/bin:\(home.path)/.tako/bin:/usr/bin:/bin"]
            let out = Pipe()
            process.standardOutput = out
            try process.run()
            process.waitUntilExit()
            return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        XCTAssertEqual(try run(""), "\(home.path)/.hyperterm|/usr/bin:/bin")
        XCTAssertEqual(DataDirectoryMigration.migrateSupportDirectory(home: home), .moved)
        XCTAssertEqual(try run(""), "\(home.path)/.tako|/usr/bin:/bin")
        XCTAssertEqual(try run("HT_HOME=/tmp/dev"), "/tmp/dev|/usr/bin:/bin")
    }
}
