import XCTest
@testable import Tako

/// Codex 0.160 against what Tako expects of it. Payloads, screens and log lines below were
/// captured from a real `codex` 0.160.1 (run against a stand-in model server).
@MainActor
final class CodexParityTests: XCTestCase {
    // MARK: - Hooks and their trust

    func testHookHashMatchesCodexs() {
        // `codex app-server` hooks/list reported this currentHash for
        // -c 'hooks.Stop=[{hooks=[{type="command",command="/x/ht hook codex"}]}]' (timeout defaults to 600).
        XCTAssertEqual(CodexAdapter.hookHash(event: "stop", command: "/x/ht hook codex", timeout: 600),
                       "sha256:18d58b48f8dadaaf0bdc0383269f6a7002e519a836c06baa95ef864bf553da2b")
        // And for two of Tako's own, exactly as the wrapper passes them.
        let overrides = CodexAdapter.hookOverrides(ht: "/Users/me/.hyperterm/bin/ht")
        XCTAssertTrue(overrides.last?.contains(#""/<session-flags>/config.toml:permission_request:0:0"={trusted_hash="sha256:3ab01255868a1f1eb7f19809798b7187b306c2c189a41da568d4a3194c2f817a"}"#) == true)
        XCTAssertTrue(overrides.last?.contains(#""/<session-flags>/config.toml:interrupt:0:0"={trusted_hash="sha256:e7a08cca87be4cce9323b4ef583bcce78821f49cd4f3f3f90ccd0f9a416d8e72"}"#) == true)
    }

    func testEveryHookIsPassedWithItsOwnTrust() throws {
        let overrides = CodexAdapter.hookOverrides(ht: "/Users/me/.hyperterm/bin/ht")
        let values = stride(from: 1, to: overrides.count, by: 2).map { overrides[$0] }
        XCTAssertTrue(stride(from: 0, to: overrides.count, by: 2).allSatisfy { overrides[$0] == "-c" })
        let hooks = values.filter { !$0.hasPrefix("hooks.state=") }
        XCTAssertEqual(hooks.map { String($0.prefix { $0 != "=" }) },
                       ["hooks.SessionStart", "hooks.UserPromptSubmit", "hooks.PreToolUse", "hooks.PostToolUse",
                        "hooks.PermissionRequest", "hooks.Stop", "hooks.Interrupt"])
        XCTAssertTrue(hooks[4].contains(#"command="/Users/me/.hyperterm/bin/ht permission codex",timeout=600"#), hooks[4])
        let state = try XCTUnwrap(values.last)
        XCTAssertTrue(state.hasPrefix("hooks.state={"))
        for key in ["session_start", "user_prompt_submit", "pre_tool_use", "post_tool_use", "permission_request", "stop", "interrupt"] {
            XCTAssertTrue(state.contains(#""/<session-flags>/config.toml:\#(key):0:0"={trusted_hash="sha256:"#), key)
        }
        let wrapper = CodexAdapter.wrapperScript(ht: "/Users/me/.hyperterm/bin/ht")
        XCTAssertTrue(wrapper.contains("exec codex --no-daemon \\\n  -c 'hooks.SessionStart="), wrapper)
        XCTAssertFalse(wrapper.contains("bypass-hook-trust"))
    }

    func testCodexHooksDriveState() {
        let session = TerminalSession(spec: LaunchSpec(label: "api", kind: .codex, cwd: "/tmp"), resume: false)
        addTeardownBlock { @MainActor in session.terminate() }
        let store = SessionStore(previewSessions: [session], previewLayout: .focus)
        let thread = "01a110ad-7491-7af1-b340-da8605e1c16e"
        func hook(_ json: [String: Any]) {
            store.applyHook(source: "codex", session: session, json: json.merging(["session_id": thread, "cwd": "/tmp"]) { a, _ in a }, sentAt: nil)
        }
        hook(["hook_event_name": "SessionStart", "source": "startup"])
        XCTAssertEqual(session.state, .idle)
        hook(["hook_event_name": "UserPromptSubmit", "prompt": "please fix it"])
        XCTAssertEqual(session.state, .working)
        XCTAssertEqual(session.spec.agentSessionId, thread, "the thread id is learned for sleep and resume")
        hook(["hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": ["command": "touch x"]])
        XCTAssertEqual(session.activity, "Bash: touch x")
        hook(["hook_event_name": "Stop", "last_assistant_message": "Done: fixed it."])
        XCTAssertEqual(session.state, .idle)
        XCTAssertEqual(session.summary, "Done: fixed it.")
        let done = session.timeline.filter { $0.kind == .done }.count
        // notify still arrives after the Stop hook; it doesn't record the turn again.
        store.applyHook(source: "codex-notify", session: session,
                        json: ["type": "agent-turn-complete", "thread-id": thread, "last-assistant-message": "Done: fixed it."], sentAt: nil)
        XCTAssertEqual(session.timeline.filter { $0.kind == .done }.count, done)
        hook(["hook_event_name": "UserPromptSubmit", "prompt": "again"])
        hook(["hook_event_name": "Interrupt"])
        XCTAssertEqual(session.state, .idle, "Esc ends a Codex turn without Stop")
    }

    func testCodexPermissionRequestNeedsYouWithTheRequest() {
        let session = TerminalSession(spec: LaunchSpec(label: "api", kind: .codex, cwd: "/tmp"), resume: false)
        addTeardownBlock { @MainActor in session.terminate() }
        let store = SessionStore(previewSessions: [session], previewLayout: .focus)
        let payload = #"{"session_id":"01a110ad-7491-7af1-b340-da8605e1c16e","turn_id":"01a110ad-9663-79d1-a3ab-ac7dbd852984","cwd":"/tmp","hook_event_name":"PermissionRequest","model":"gpt-5.1-codex","permission_mode":"default","tool_name":"Bash","tool_input":{"command":"touch /tmp/kuronami-mock-escalate","description":"Mock needs to write outside the workspace"}}"#
        final class Decision: @unchecked Sendable { var text: String? }
        let decision = Decision()
        store.registerApproval(for: session, source: "codex", payload: payload) { decision.text = $0.text }
        XCTAssertEqual(session.state, .needsInput("Bash: touch /tmp/kuronami-mock-escalate"))
        XCTAssertTrue(session.hasHookApproval)
        _ = store.answer(session, .approve)
        // The shape Codex honoured live: the command ran.
        XCTAssertTrue(decision.text?.contains(#""behavior":"allow""#) == true, decision.text ?? "")
        XCTAssertTrue(decision.text?.contains(#""hookEventName":"PermissionRequest""#) == true)
    }

    // MARK: - Screens

    /// 0.160.1's first screens at 120 columns.
    private let trustScreen = """
      Folder access
      /private/tmp/fresh3

      Trust this folder? Codex can read, edit, and run files here, subject to your permission settings. Folder settings
      can run code automatically, even without a model request. Continue only if you trust these files. Your trust
      decision will be saved.

    › 1. Trust and continue
      2. Quit

      enter continue · esc quit
    """

    private let signInScreen = """
      Welcome to Codex, OpenAI's command-line coding agent

      Sign in with ChatGPT to use Codex as part of your paid plan
      or connect an API key for usage-based billing

    > 1. Sign in with ChatGPT
         Usage included with Plus, Pro, Business, and Enterprise plans
      2. Sign in with Device Code
         Sign in from another device with a one-time code
      3. Provide your own API key
         Pay for what you use

      Press enter to continue
    """

    func testTrustAndSignInScreens() {
        XCTAssertTrue(PromptScreen.hasTrustDialog(trustScreen))
        XCTAssertFalse(PromptScreen.hasSignIn(trustScreen, kind: .codex))
        XCTAssertTrue(PromptScreen.hasSignIn(signInScreen, kind: .codex))
        XCTAssertFalse(PromptScreen.hasTrustDialog(signInScreen))
        XCTAssertFalse(PromptScreen.hasSignIn(signInScreen, kind: .claude))
    }

    func testSignInScreenNeedsYouThenTrustThenStarts() {
        let session = TerminalSession(spec: LaunchSpec(label: "api", kind: .codex, cwd: "/tmp"), resume: false)
        addTeardownBlock { @MainActor in session.terminate() }
        session.trustPromptSeen(true, reason: "Sign in to Codex")
        XCTAssertEqual(session.state, .needsInput("Sign in to Codex"))
        XCTAssertTrue(TerminalSession.isUsersOwn("Sign in to Codex"), "never handed to Sumi")
        session.trustPromptSeen(true)
        XCTAssertEqual(session.state, .needsInput(TerminalSession.trustReason))
        session.trustPromptSeen(false)
        XCTAssertEqual(session.state, .starting)
    }

    // MARK: - Processes

    func testNpmCodexIsTheCLINotWork() {
        XCTAssertTrue(StewardRules.isAgentMachinery(name: "codex", path: "/opt/homebrew/Caskroom/codex/0.160.1/bin/codex"))
        XCTAssertTrue(StewardRules.isAgentMachinery(name: "node", path: "/opt/homebrew/bin/node", script: "/opt/homebrew/bin/codex"))
        XCTAssertTrue(StewardRules.isAgentMachinery(name: "node", path: "/opt/homebrew/bin/node",
                                                    script: "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex.js"))
        XCTAssertFalse(StewardRules.isAgentMachinery(name: "node", path: "/opt/homebrew/bin/node", script: "/Users/me/app/server.js"))
    }

    // MARK: - Options

    func testModesUseFlagsCodex0160Accepts() {
        // 0.160 rejects `-a untrusted` and `--full-auto`.
        for mode in PermissionMode.allCases {
            let args = AgentOptions(mode: mode).arguments(for: .codex)
            XCTAssertFalse(args.contains("untrusted") || args.contains("--full-auto"), "\(mode)")
        }
        XCTAssertEqual(AgentOptions(mode: .supervised).arguments(for: .codex),
                       ["--ask-for-approval", "on-request", "--sandbox", "read-only"])
    }

    // MARK: - Rollout

    /// Lines from a 0.160.1 rollout (long ids and the injected context trimmed).
    private let rollout = #"""
    {"timestamp":"2026-10-06T10:06:05.523Z","type":"session_meta","payload":{"session_id":"01a110ad-7491-7af1-b340-da8605e1c16e","id":"01a110ad-7491-7af1-b340-da8605e1c16e"}}
    {"timestamp":"2026-10-06T10:06:14.200Z","type":"event_msg","payload":{"type":"task_started","turn_id":"t1","model_context_window":258400}}
    {"timestamp":"2026-10-06T10:06:14.201Z","type":"response_item","payload":{"type":"message","id":"m0","role":"developer","content":[{"type":"input_text","text":"<permissions instructions>"}]}}
    {"timestamp":"2026-10-06T10:06:14.202Z","type":"response_item","payload":{"type":"message","id":"m1","role":"user","content":[{"type":"input_text","text":"<environment_context>\n  <cwd>/tmp</cwd>\n</environment_context>"}]}}
    {"timestamp":"2026-10-06T10:06:14.230Z","type":"response_item","payload":{"type":"message","id":"msg_01a110ad","role":"user","content":[{"type":"input_text","text":"please ESCALATE now"}]}}
    {"timestamp":"2026-10-06T10:06:14.233Z","ordinal":7,"type":"event_msg","payload":{"type":"item_completed","thread_id":"01a110ad-7491-7af1-b340-da8605e1c16e","turn_id":"t1","item":{"type":"UserMessage","id":"u1","content":[{"type":"text","text":"please ESCALATE now","text_elements":[]}]}}}
    {"timestamp":"2026-10-06T10:06:14.248Z","ordinal":8,"type":"response_item","payload":{"type":"function_call","id":"fc_1","name":"exec_command","arguments":"{\"cmd\": \"touch /tmp/kuronami-mock-escalate\", \"sandbox_permissions\": \"require_escalated\", \"justification\": \"Mock needs to write outside the workspace\"}","call_id":"call_1"}}
    {"timestamp":"2026-10-06T10:06:14.312Z","ordinal":10,"type":"event_msg","payload":{"type":"item_completed","thread_id":"01a110ad-7491-7af1-b340-da8605e1c16e","turn_id":"t1","item":{"type":"CommandExecution","id":"call_1","command":["/bin/zsh","-lc","touch /tmp/kuronami-mock-escalate"],"status":"completed","exit_code":0}}}
    {"timestamp":"2026-10-06T10:06:14.328Z","ordinal":11,"type":"response_item","payload":{"type":"function_call_output","id":"fco_1","call_id":"call_1","output":"Process exited with code 0\nOutput:\n"}}
    {"timestamp":"2026-10-06T10:06:14.332Z","ordinal":13,"type":"event_msg","payload":{"type":"item_completed","thread_id":"01a110ad-7491-7af1-b340-da8605e1c16e","turn_id":"t1","item":{"type":"AgentMessage","id":"msg_3","content":[{"type":"Text","text":"MOCK REPLY 3"}]}}}
    {"timestamp":"2026-10-06T10:06:14.332Z","ordinal":14,"type":"response_item","payload":{"type":"message","id":"msg_3","role":"assistant","content":[{"type":"output_text","text":"MOCK REPLY 3"}]}}
    {"timestamp":"2026-10-06T10:06:14.333Z","ordinal":16,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":200,"output_tokens":10,"total_tokens":210},"last_token_usage":{"input_tokens":100,"output_tokens":5,"total_tokens":105},"model_context_window":258400},"rate_limits":{"limit_id":"codex","limit_name":null,"primary":null,"secondary":null,"credits":null,"plan_type":null,"rate_limit_reached_type":null}}}
    {"timestamp":"2026-10-06T10:06:14.342Z","ordinal":17,"type":"event_msg","payload":{"type":"task_complete","turn_id":"t1","last_agent_message":"MOCK REPLY 3"}}
    """#

    func testRendersA0160Rollout() {
        XCTAssertEqual(AgentTranscript.renderCodex(rollout[...]), [
            "› please ESCALATE now",
            "[tool] exec_command: touch /tmp/kuronami-mock-escalate",
            "MOCK REPLY 3",
        ])
    }

    func testReadsUsageFromA0160Rollout() throws {
        let reading = try XCTUnwrap(CodexUsage.latest(in: rollout[...]))
        XCTAssertEqual(try XCTUnwrap(reading.contextPercent), 105.0 / 258_400 * 100, accuracy: 0.0001)
        XCTAssertNil(reading.limits)
        XCTAssertFalse(reading.limitReached)
    }

    func testResumesAndFindsTheRolloutByThreadId() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-parity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let day = root.appendingPathComponent("sessions/2026/10/06")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let thread = "01a110ad-7491-7af1-b340-da8605e1c16e"
        try rollout.write(to: day.appendingPathComponent("rollout-2026-10-06T15-36-05-\(thread).jsonl"), atomically: true, encoding: .utf8)
        XCTAssertEqual(AgentTranscript.conversation(kind: .codex, id: thread, cwds: [], root: root).last, "MOCK REPLY 3")

        var spec = LaunchSpec(label: "api", kind: .codex, cwd: "/tmp")
        spec.agentSessionId = thread
        let line = try XCTUnwrap(AgentIntegration.initialInput(for: spec, resume: true))
        XCTAssertTrue(line.hasSuffix("/codex' resume '\(thread)'\n"), line)
    }
}
