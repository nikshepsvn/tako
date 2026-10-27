import XCTest
@testable import Tako

/// A signed-out Codex shows its sign-in menu as a question, and can be signed in with a device code.
@MainActor
final class CodexSignInTests: XCTestCase {
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

    func testTheSignInMenuBecomesASingleSelectQuestion() {
        XCTAssertTrue(PromptScreen.hasSignIn(signInScreen, kind: .codex))
        let question = PendingQuestion.fromScreen(signInScreen, question: "Sign in to Codex")
        XCTAssertEqual(question.mode, .options)
        XCTAssertTrue(question.selectsByNumber)
        XCTAssertEqual(question.items[0].question, "Sign in to Codex")
        XCTAssertEqual(question.items[0].options, [
            .init(label: "Sign in with ChatGPT", description: "Usage included with Plus, Pro, Business, and Enterprise plans"),
            .init(label: "Sign in with Device Code", description: "Sign in from another device with a one-time code"),
            .init(label: "Provide your own API key", description: "Pay for what you use"),
        ])
    }

    func testTheOtherSelectionMarkerAndMissingDescriptions() {
        let screen = "› 1. Sign in with ChatGPT\n  2. Sign in with Device Code\n\n  Press enter to continue"
        let question = PendingQuestion.fromScreen(screen, question: "Sign in to Codex")
        XCTAssertEqual(question.items[0].options, [
            .init(label: "Sign in with ChatGPT", description: nil),
            .init(label: "Sign in with Device Code", description: nil),
        ])
    }

    func testScreenQuestionsPressTheNumberAndHookQuestionsWalkTheList() {
        let screen = PendingQuestion.fromScreen(signInScreen, question: "Sign in to Codex")
        XCTAssertEqual(screen.keysToPick(option: 0), ["1"])
        XCTAssertEqual(screen.keysToPick(option: 1), ["2"])
        XCTAssertEqual(screen.keysToPick(option: 2), ["3"])
        let hook = PendingQuestion.parse(toolInput: ["questions": [["question": "Pick", "options": [["label": "A"], ["label": "B"]]]]])
        XCTAssertFalse(hook.selectsByNumber)
        XCTAssertEqual(hook.keysToPick(option: 1), ["down", "enter"])
    }

    func testDeviceCodeOnSeparateLines() {
        let screen = """
          Welcome to Codex, OpenAI's command-line coding agent

          Follow these steps to sign in with ChatGPT using device code authorization:

          1. Open this link in your browser and sign in to your account
             https://auth.openai.com/codex/device

          2. Enter this one-time code (expires in 15 minutes)
             ABCD-EFGHI

          Device codes are a common phishing target. Never share this code.
        """
        let found = PromptScreen.deviceCode(in: screen)
        XCTAssertEqual(found?.url, "https://auth.openai.com/codex/device")
        XCTAssertEqual(found?.code, "ABCD-EFGHI")
        XCTAssertFalse(PromptScreen.hasSignIn(screen, kind: .codex), "the code screen is not the menu, so the wait clears")
    }

    func testDeviceCodeOnOneLineWithADigitCode() {
        let found = PromptScreen.deviceCode(in: "Go to https://auth.openai.com/codex/device. Code: WXYZ-12345")
        XCTAssertEqual(found?.url, "https://auth.openai.com/codex/device")
        XCTAssertEqual(found?.code, "WXYZ-12345")
        XCTAssertEqual(PromptScreen.deviceCode(in: "https://auth.openai.com/codex/device\nABCD-1234")?.code, "ABCD-1234")
    }

    func testNoDeviceCodeUntilBothShow() {
        XCTAssertNil(PromptScreen.deviceCode(in: signInScreen))
        XCTAssertNil(PromptScreen.deviceCode(in: "https://auth.openai.com/codex/device\nRequesting a code…"))
        XCTAssertNil(PromptScreen.deviceCode(in: "Enter this one-time code\n  ABCD-EFGH"))
        XCTAssertNil(PromptScreen.signInFailure(in: signInScreen))
        XCTAssertEqual(PromptScreen.signInFailure(in: "  Device code login is not enabled for this workspace  \n"),
                       "Device code login is not enabled for this workspace")
    }

    func testDeviceCodeSignInNeedsTheSignInScreen() {
        let session = TerminalSession(spec: LaunchSpec(label: "cx", kind: .shell, cwd: "/tmp"), resume: false)
        var result: Result<String, TerminalSession.PromptError>?
        session.signInWithDeviceCode { result = $0 }
        guard case .failure(.noPromptOnScreen)? = result else { return XCTFail("not a Codex sign-in screen: \(String(describing: result))") }
        session.terminate()
    }
}
