import XCTest
@testable import Tako

/// The sidebar card shows what an agent asked, not Allow / Deny.
@MainActor
final class PendingQuestionTests: XCTestCase {
    private func ask(_ questions: [[String: Any]]) -> [String: Any] { ["questions": questions] }

    private let colors: [String: Any] = [
        "question": "Which color?", "header": "Color", "multiSelect": false,
        "options": [["label": "Red", "description": "Warm"], ["label": "Blue", "description": ""]],
    ]

    func testParsesQuestionOptionsAndDescriptions() {
        let parsed = PendingQuestion.parse(toolInput: ask([colors]))
        XCTAssertEqual(parsed.mode, .options)
        let item = parsed.items[0]
        XCTAssertEqual(item.question, "Which color?")
        XCTAssertEqual(item.header, "Color")
        XCTAssertEqual(item.options, [.init(label: "Red", description: "Warm"), .init(label: "Blue", description: nil)])
    }

    func testMissingOrMalformedPayloadIsUnavailable() {
        XCTAssertEqual(PendingQuestion.parse(toolInput: [:]).mode, .unavailable)
        XCTAssertEqual(PendingQuestion.parse(toolInput: ["questions": "nope"]).mode, .unavailable)
        XCTAssertEqual(PendingQuestion.parse(toolInput: ask([["options": []]])).mode, .unavailable)
        XCTAssertEqual(PendingQuestion.parse(toolInput: ask([["question": "  "]])).mode, .unavailable)
    }

    func testMultiSelectAndSeveralQuestionsFallBackToTheTerminal() {
        var multi = colors
        multi["multiSelect"] = true
        XCTAssertEqual(PendingQuestion.parse(toolInput: ask([multi])).mode, .terminalOnly)
        XCTAssertEqual(PendingQuestion.parse(toolInput: ask([colors, colors])).mode, .terminalOnly)
        // A question with no usable options can't be answered from the card either.
        XCTAssertEqual(PendingQuestion.parse(toolInput: ask([["question": "Why?", "options": [["label": ""]]]])).mode, .terminalOnly)
    }

    func testOptionsWithoutLabelsAreDroppedAndLongTextIsKept() {
        let long = String(repeating: "very long label ", count: 20)
        let parsed = PendingQuestion.parse(toolInput: ask([[
            "question": long, "options": [["label": long], ["description": "no label"], ["label": "B"]],
        ]]))
        XCTAssertEqual(parsed.items[0].options.map(\.label), [long.trimmingCharacters(in: .whitespaces), "B"])
        XCTAssertEqual(parsed.items[0].question, long.trimmingCharacters(in: .whitespaces))
    }

    func testManyOptionsAreAllKept() {
        let options = (1...9).map { ["label": "Option \($0)"] }
        let parsed = PendingQuestion.parse(toolInput: ask([["question": "Pick", "options": options]]))
        XCTAssertEqual(parsed.items[0].options.count, 9)
        XCTAssertEqual(parsed.mode, .options)
    }

    func testKeysWalkDownFromTheFirstOptionThenEnter() {
        XCTAssertEqual(PendingQuestion.keys(forOption: 0), ["enter"])
        XCTAssertEqual(PendingQuestion.keys(forOption: 2), ["down", "down", "enter"])
        XCTAssertEqual(PendingQuestion.keys(forOption: -1), ["enter"])
    }

    func testPreToolUseCapturesTheQuestionAndPostToolUseClearsIt() {
        let session = TerminalSession(spec: LaunchSpec(label: "api", kind: .claude, cwd: "/workspace/atlas"), resume: false)
        let store = SessionStore(previewSessions: [session], previewLayout: .focus)
        store.applyHook(source: "claude", session: session,
                        json: ["hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion", "tool_input": ask([colors])], sentAt: nil)
        XCTAssertEqual(session.pendingQuestion?.mode, .options)

        store.applyHook(source: "claude", session: session,
                        json: ["hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion", "tool_input": [String: Any]()], sentAt: nil)
        XCTAssertEqual(session.pendingQuestion?.mode, .unavailable)

        store.applyHook(source: "claude", session: session,
                        json: ["hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": ["command": "ls"]], sentAt: nil)
        XCTAssertNil(session.pendingQuestion, "an ordinary tool is not a question")

        session.pendingQuestion = PendingQuestion.parse(toolInput: ask([colors]))
        store.applyHook(source: "claude", session: session,
                        json: ["hook_event_name": "PostToolUse", "tool_name": "AskUserQuestion"], sentAt: nil)
        XCTAssertNil(session.pendingQuestion, "answered in the terminal itself")
    }

    func testAnsweringNeedsAWaitingAgentAndAnOptionsQuestion() {
        let session = TerminalSession(spec: LaunchSpec(label: "api", kind: .claude, cwd: "/workspace/atlas"), resume: false)
        session.pendingQuestion = PendingQuestion.parse(toolInput: ask([colors]))
        guard case .failure = session.answerQuestionByKeys(option: 0) else { return XCTFail("not waiting") }

        session.apply(.processStarted, source: "test", force: .needsInput("Which color?"))
        session.pendingQuestion = PendingQuestion.parse(toolInput: ask([colors, colors]))
        guard case .failure = session.answerQuestionByKeys(option: 0) else { return XCTFail("two questions are answered in the terminal") }
        session.pendingQuestion = PendingQuestion.parse(toolInput: ask([colors]))
        guard case .failure = session.answerQuestionByKeys(option: 5) else { return XCTFail("no such option") }
    }

    func testTheQuestionLeavesWithTheWait() {
        let session = TerminalSession(spec: LaunchSpec(label: "api", kind: .claude, cwd: "/workspace/atlas"), resume: false)
        session.apply(.processStarted, source: "test", force: .needsInput("Which color?"))
        session.pendingQuestion = PendingQuestion.parse(toolInput: ask([colors]))
        session.apply(.userSubmitted, source: "test", force: .working)
        XCTAssertNil(session.pendingQuestion)
    }
}
