import XCTest
@testable import Tako

/// What a session remembers once it is closed, and that older saved specs still load.
final class SessionMemoryTests: XCTestCase {
    func testSpecSavedBeforeMemoryStillDecodes() throws {
        let json = """
        {"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","label":"api","kind":"claude","cwd":"~/code/api",
         "agentSessionId":"abc-123","createdAt":"2026-01-02T03:04:05Z"}
        """
        let spec = try decoder().decode(LaunchSpec.self, from: Data(json.utf8))

        XCTAssertEqual(spec.label, "api")
        XCTAssertNil(spec.memory)
        XCTAssertTrue(spec.canResume)
    }

    func testMemoryRoundTrips() throws {
        var spec = LaunchSpec(label: "web", kind: .codex, cwd: "/tmp")
        spec.memory = SessionMemory(task: "Add a login page", lastActiveAt: Date(timeIntervalSince1970: 1_700_000_000),
                                    closedAt: Date(timeIntervalSince1970: 1_700_000_600), finalState: "Needs you: approve rm",
                                    events: ["Edited login.tsx", "Tests pass"])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let decoded = try decoder().decode(LaunchSpec.self, from: encoder.encode(spec))

        XCTAssertEqual(decoded.memory, spec.memory)
        XCTAssertFalse(decoded.canResume)
    }

    func testAgentWithoutConversationReopensFresh() {
        let spec = LaunchSpec(label: "web", kind: .claude, cwd: "/tmp")
        let input = AgentIntegration.initialInput(for: spec, resume: spec.canResume)

        XCTAssertEqual(input?.contains("--resume"), false)
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
