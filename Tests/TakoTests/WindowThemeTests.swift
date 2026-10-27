import AppKit
import XCTest
@testable import Tako

/// View › Theme. Uses its own defaults suite: the test host shares the app's.
final class WindowThemeTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "WindowThemeTests"

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    func testNightIsTheDefault() {
        XCTAssertEqual(WindowTheme.load(from: defaults), .night)
    }

    func testChoiceSurvivesARelaunch() {
        WindowTheme.original.save(to: defaults)
        XCTAssertEqual(WindowTheme.load(from: defaults), .original)
        WindowTheme.night.save(to: defaults)
        XCTAssertEqual(WindowTheme.load(from: defaults), .night)
    }

    func testUnknownStoredValueFallsBackToNight() {
        defaults.set("sepia", forKey: WindowTheme.defaultsKey)
        XCTAssertEqual(WindowTheme.load(from: defaults), .night)
    }

    func testNightIsOneSeeThroughTone() {
        let night = WindowTheme.night
        XCTAssertTrue(night.isTranslucent)
        XCTAssertEqual(night.paneFill, night.canvasFill)
        XCTAssertEqual(night.paneFill.alphaComponent, 0.72, accuracy: 0.001)
        XCTAssertLessThan(night.paneFill.luminance, 0.05)
        // Headers and terminal backings show the canvas, so they match the sidebar.
        XCTAssertEqual(night.tileFill(terminal: .red).alphaComponent, 0)
        XCTAssertLessThan(night.windowFill.alphaComponent, 0.01)
    }

    func testOriginalIsOpaqueSumi() {
        let original = WindowTheme.original
        XCTAssertFalse(original.isTranslucent)
        XCTAssertEqual(original.paneFill, Ink.deep)
        XCTAssertEqual(original.canvasFill, Ink.floor)
        XCTAssertEqual(original.windowFill, Ink.floor)
        XCTAssertEqual(original.tileFill(terminal: .red), .red)
    }
}
