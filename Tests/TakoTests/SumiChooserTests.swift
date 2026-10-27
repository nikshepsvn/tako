import XCTest
@testable import Tako

@MainActor
final class SumiChooserTests: XCTestCase {
    func testStartVerdicts() {
        typealias O = SumiOnboarding
        XCTAssertEqual(O.startVerdict(exited: nil, launching: true, elapsed: 1), .waiting)
        XCTAssertEqual(O.startVerdict(exited: nil, launching: false, elapsed: 1), .failed)
        XCTAssertEqual(O.startVerdict(exited: true, launching: false, elapsed: 2), .failed)
        XCTAssertEqual(O.startVerdict(exited: false, launching: false, elapsed: 2), .waiting)
        XCTAssertEqual(O.startVerdict(exited: false, launching: false, elapsed: O.startWindow), .started)
        XCTAssertEqual(O.failureMessage(kind: .codex, modelTitle: "GPT-6-Luna"), "Codex couldn't start with GPT-6-Luna.")
    }
}
