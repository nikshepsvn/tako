import AppKit
import XCTest
@testable import Tako

@MainActor
final class DiffLayoutTests: XCTestCase {
    private let patch = """
    diff --git a/a.swift b/a.swift
    --- a/a.swift
    +++ b/a.swift
    @@ -1,4 +1,4 @@
     let a = 1
    -let b = 2
    -let c = 3
    +let b = 20
     let d = 4
    """

    func testOldAndNewLineNumbers() {
        let lines = PatchLine.parse(patch)
        XCTAssertEqual(lines.map(\.kind), [.header, .context, .removed, .removed, .added, .context])
        XCTAssertEqual(lines[2].oldNumber, 2)
        XCTAssertEqual(lines[3].oldNumber, 3)
        XCTAssertEqual(lines[4].newNumber, 2)
        XCTAssertEqual(lines[5].oldNumber, 4)
        XCTAssertEqual(lines[5].newNumber, 3)
    }

    func testSplitRowsPairRemovalsWithAdditions() {
        let rows = SplitRow.rows(from: PatchLine.parse(patch))
        XCTAssertNotNil(rows[0].header)
        XCTAssertEqual(rows[1].left?.text, "let a = 1")
        XCTAssertEqual(rows[1].right?.text, "let a = 1")
        XCTAssertEqual(rows[2].left?.text, "let b = 2")
        XCTAssertEqual(rows[2].right?.text, "let b = 20")
        XCTAssertEqual(rows[3].left?.text, "let c = 3")
        XCTAssertNil(rows[3].right)
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count, "row ids are unique")
    }

    func testDocumentsKeepEveryLineAndMarkChanges() {
        let lines = PatchLine.parse(patch)
        let unified = DiffDocument.unified(lines)
        XCTAssertEqual(unified.string.components(separatedBy: "\n").count - 1, lines.count)
        XCTAssertTrue(unified.string.contains("let b = 20"))
        var kinds: [String] = []
        unified.enumerateAttribute(DiffDocument.kindKey, in: NSRange(location: 0, length: unified.length)) { value, _, _ in
            if let value = value as? String, kinds.last != value { kinds.append(value) }
        }
        XCTAssertEqual(kinds, ["header", "context", "removed", "added", "context"])
        let split = DiffDocument.split(lines)
        XCTAssertTrue(split.string.contains("let c = 3"))
    }

    func testALargeDiffBuildsQuickly() {
        let body = (1...20_000).map { "+line \($0)" }.joined(separator: "\n")
        let lines = PatchLine.parse("@@ -0,0 +1,20000 @@\n" + body)
        measure { _ = DiffDocument.unified(lines) }
    }
}
