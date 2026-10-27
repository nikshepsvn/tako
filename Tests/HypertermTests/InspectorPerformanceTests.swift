import AppKit
import Darwin
import XCTest
@testable import Hyperterm

final class InspectorPerformanceTests: XCTestCase {
    private final class Counter {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        func increment() { lock.lock(); count += 1; lock.unlock() }
    }

    private func fixture() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("kuronami-inspector-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        // Foundation may collapse macOS's /private/var alias; git reports the physical path.
        let physical = try XCTUnwrap(realpath(path.path, nil))
        defer { free(physical) }
        return URL(fileURLWithPath: String(cString: physical))
    }

    private func repository(at path: URL) throws {
        XCTAssertNotNil(runGit(["init", "-b", "main", path.path]))
        XCTAssertNotNil(runGit(["-C", path.path, "-c", "user.name=Tako Test", "-c", "user.email=test@example.invalid",
                                "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "Fixture"]))
    }

    func testStableMetadataSkipsSubprocessesAndPeriodicallyRechecks() throws {
        let path = try fixture()
        defer { try? FileManager.default.removeItem(at: path) }
        try repository(at: path)
        var now: TimeInterval = 0
        let calls = Counter()
        let inspector = GitInspector(clock: { now }, git: { calls.increment(); return runGit($0) })
        let initial = try XCTUnwrap(inspector.info(for: path.path))
        for tick in stride(from: 9.0, through: 54.0, by: 9.0) {
            now = tick
            XCTAssertEqual(inspector.info(for: path.path), initial)
        }
        XCTAssertEqual(calls.value, 1, "Stable metadata should not spawn git each poll")
        now = 63
        XCTAssertEqual(inspector.info(for: path.path), initial)
        XCTAssertEqual(calls.value, 2, "Repository topology still gets a periodic full probe")
    }

    func testBranchChangeInvalidatesMetadataCache() throws {
        let path = try fixture()
        defer { try? FileManager.default.removeItem(at: path) }
        try repository(at: path)
        var now: TimeInterval = 0
        let calls = Counter()
        let inspector = GitInspector(clock: { now }, git: { calls.increment(); return runGit($0) })
        XCTAssertEqual(inspector.info(for: path.path)?.branch, "main")
        XCTAssertNotNil(runGit(["-C", path.path, "switch", "-c", "feature/new-head"]))
        now = 9
        XCTAssertEqual(inspector.info(for: path.path)?.branch, "feature/new-head")
        XCTAssertEqual(calls.value, 2)
    }

    func testNestedRepositoryCreationInvalidatesAncestorLookup() throws {
        let path = try fixture()
        defer { try? FileManager.default.removeItem(at: path) }
        try repository(at: path)
        let nested = path.appendingPathComponent("nested")
        let working = nested.appendingPathComponent("src/module")
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
        var now: TimeInterval = 0
        let inspector = GitInspector(clock: { now })
        XCTAssertEqual(inspector.info(for: working.path)?.root, path.path)
        try repository(at: nested)
        now = 9
        XCTAssertEqual(inspector.info(for: working.path)?.root, nested.path)
        XCTAssertEqual(inspector.info(for: working.path)?.mainRoot, nested.path)
    }

    func testNestedDirectoryReportsAbsoluteMainRepositoryRoot() throws {
        let path = try fixture()
        defer { try? FileManager.default.removeItem(at: path) }
        try repository(at: path)
        let nested = path.appendingPathComponent("a/b/c")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let info = try XCTUnwrap(GitInspector.query(nested.path))
        XCTAssertEqual(info.root, path.path)
        XCTAssertEqual(info.mainRoot, path.path)
        XCTAssertFalse(info.isWorktree)
    }

    func testWorktreeHeadAndPointerReplacementInvalidateCache() throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let main = folder.appendingPathComponent("main")
        try repository(at: main)
        let first = folder.appendingPathComponent("first")
        let second = folder.appendingPathComponent("second")
        XCTAssertNotNil(runGit(["-C", main.path, "worktree", "add", "-b", "first", first.path]))
        XCTAssertNotNil(runGit(["-C", main.path, "worktree", "add", "-b", "second", second.path]))
        var now: TimeInterval = 0
        let calls = Counter()
        let inspector = GitInspector(clock: { now }, git: { calls.increment(); return runGit($0) })
        let initial = try XCTUnwrap(inspector.info(for: first.path))
        XCTAssertTrue(initial.isWorktree)
        XCTAssertEqual(initial.mainRoot, main.path)
        XCTAssertEqual(initial.branch, "first")
        XCTAssertNotNil(runGit(["-C", first.path, "switch", "-c", "updated-first"]))
        now = 9
        XCTAssertEqual(inspector.info(for: first.path)?.branch, "updated-first")
        let replacement = try String(contentsOf: second.appendingPathComponent(".git"), encoding: .utf8)
        try replacement.write(to: first.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        now = 18
        let fresh = try XCTUnwrap(GitInspector.query(first.path))
        XCTAssertEqual(fresh.branch, "second")
        XCTAssertEqual(inspector.info(for: first.path), fresh)
        XCTAssertEqual(calls.value, 3)
    }

    func testDetachedHeadAndNewRepositoryRemainDiscoverable() throws {
        let path = try fixture()
        defer { try? FileManager.default.removeItem(at: path) }
        var now: TimeInterval = 0
        let inspector = GitInspector(clock: { now })
        XCTAssertNil(inspector.info(for: path.path))
        try repository(at: path)
        now = 9
        XCTAssertEqual(inspector.info(for: path.path)?.branch, "main")
        XCTAssertNotNil(runGit(["-C", path.path, "checkout", "--detach", "HEAD"]))
        now = 18
        XCTAssertEqual(inspector.info(for: path.path)?.branch, "HEAD")
    }

    func testConcurrentIdenticalQueriesShareOneSubprocess() throws {
        let path = try fixture()
        defer { try? FileManager.default.removeItem(at: path) }
        try repository(at: path)
        let calls = Counter()
        let inspector = GitInspector(clock: { 0 }, git: {
            calls.increment()
            Thread.sleep(forTimeInterval: 0.03)
            return runGit($0)
        })
        let group = DispatchGroup()
        for _ in 0..<8 {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                _ = inspector.info(for: path.path)
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(calls.value, 1)
    }

    func testMissingProcessIdentityStillFailsClosed() {
        XCTAssertEqual(ProcessInspector().identify(pid: -1), .unknown)
    }

    // MARK: - Main thread and spawned terminals

    /// The helpers spinner steps in the render server: no TimelineView redrawing the sidebar.
    @MainActor
    func testSpinnerAnimatesWithCoreAnimationAndHoldsStillForReduceMotion() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 20), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        let spinner = BrailleSpinner.SpinnerView(frame: NSRect(x: 0, y: 0, width: 12, height: 14))
        window.contentView?.addSubview(spinner)
        let glyph = try XCTUnwrap(spinner.layer?.sublayers?.first)
        let animation = try XCTUnwrap(glyph.animation(forKey: BrailleSpinner.SpinnerView.animationKey) as? CAKeyframeAnimation)
        XCTAssertEqual(animation.values?.count, BrailleSpinner.SpinnerView.frames.count)
        XCTAssertEqual(animation.calculationMode, .discrete)
        XCTAssertEqual(animation.repeatCount, .infinity)
        XCTAssertNotNil(glyph.contents)

        spinner.reduceMotion = true
        XCTAssertNil(glyph.animation(forKey: BrailleSpinner.SpinnerView.animationKey))
        XCTAssertNotNil(glyph.contents, "Reduce Motion still shows one glyph")
    }

    /// Descriptors Tako opened without close-on-exec (as Chromium does) must not reach a shell.
    func testDescriptorsAreMarkedCloseOnExecBeforeATerminalSpawns() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("tako-fd-\(UUID().uuidString)").path
        let file = open(path, O_CREAT | O_RDWR, 0o600)
        XCTAssertGreaterThan(file, STDERR_FILENO)
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer {
            ([file] + pair).forEach { close($0) }
            unlink(path)
        }
        for fd in [file] + pair { XCTAssertEqual(fcntl(fd, F_GETFD) & FD_CLOEXEC, 0) }

        XCTAssertGreaterThanOrEqual(InheritedDescriptors.closeOnExec(), 3)
        for fd in [file] + pair { XCTAssertNotEqual(fcntl(fd, F_GETFD) & FD_CLOEXEC, 0) }
        XCTAssertEqual(fcntl(STDIN_FILENO, F_GETFD) & FD_CLOEXEC, 0, "stdio is left alone")
        XCTAssertEqual(InheritedDescriptors.closeOnExec(), 0, "A second pass finds nothing to change")
    }
}
