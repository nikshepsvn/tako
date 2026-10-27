import XCTest
@testable import Tako

final class ModelFixTests: XCTestCase {
    func testRefusedSleepCandidateIsOfferedAgainAfterAnotherQuietStretch() {
        var tracker = SleepTracker()
        tracker.after = 600
        let start = Date()
        _ = tracker.update(sessionID: "a", band: .idle, cpu: 0.2, now: start)
        XCTAssertTrue(tracker.update(sessionID: "a", band: .idle, cpu: 0.2, now: start + 600))
        tracker.retry("a", now: start + 600)
        XCTAssertFalse(tracker.update(sessionID: "a", band: .idle, cpu: 0.2, now: start + 1199), "no spam")
        XCTAssertTrue(tracker.update(sessionID: "a", band: .idle, cpu: 0.2, now: start + 1200))
    }
}
