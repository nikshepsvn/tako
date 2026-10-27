import AppKit
import XCTest
@testable import Tako

/// Regressions from the memory soak (scripts/soak.sh): what grew without bound over a long run.
final class MemoryGrowthTests: XCTestCase {
    // MARK: - Scrollback

    func testUserScrollbackAboveCapIsCapped() {
        let config = "font-size = 13\nscrollback-limit = 100000000\n"
        XCTAssertEqual(ScrollbackCap.cappedLimit(configText: config), ScrollbackCap.maxBytes)
    }

    func testLastScrollbackSettingWins() {
        XCTAssertNil(ScrollbackCap.cappedLimit(configText: "scrollback-limit = 100_000_000\nscrollback-limit = 2000000"))
        XCTAssertNotNil(ScrollbackCap.cappedLimit(configText: "scrollback-limit=5000000\nscrollback-limit = 50_000_000"))
    }

    func testSmallOrMissingScrollbackIsLeftAlone() {
        XCTAssertNil(ScrollbackCap.cappedLimit(configText: "scrollback-limit = 1000000"))
        XCTAssertNil(ScrollbackCap.cappedLimit(configText: "# scrollback-limit = 100000000\ntheme = dark"))
        XCTAssertNil(ScrollbackCap.cappedLimit(configText: ""))
    }

    func testConfigFilesFollowXDG() {
        let files = ScrollbackCap.userConfigFiles(environment: ["XDG_CONFIG_HOME": "/x"], home: URL(fileURLWithPath: "/h"))
        XCTAssertEqual(files.first?.path, "/x/ghostty/config")
        XCTAssertEqual(files.last?.path, "/h/Library/Application Support/com.mitchellh.ghostty/config.ghostty")
    }
}
