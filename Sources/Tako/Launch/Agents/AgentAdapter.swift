import Foundation

/// Everything Tako knows about one agent CLI: how it launches and resumes, how it reports
/// to Tako, where it keeps conversations and accounts, and how its screen reads. One
/// implementation per CLI; call sites ask `kind.adapter` instead of switching on the kind.
protocol AgentAdapter: Sendable {
    /// The command typed to run it, its wrapper's name in ~/.hyperterm/bin, and its process name.
    var command: String { get }

    // MARK: Launch

    /// Writes its wrapper (and any per-launch config it reads) into the launch directory.
    func install(hookPort: UInt16?)
    /// The line typed into the shell to start or resume it. `options`, `extra` and `prompt` come
    /// shell-quoted, each with its leading space.
    func launchCommand(for spec: LaunchSpec, resume: Bool, options: String, extra: String, prompt: String) -> String
    /// The CLI's own flags for Tako's launch choices.
    func arguments(for options: AgentOptions) -> [String]
    /// Whether Tako picks the conversation id at launch (so resume never waits on a hook).
    var assignsSessionID: Bool { get }
    /// Resumes a conversation outside Tako, for copying.
    func resumeCommand(_ id: String) -> String

    // MARK: Conversation

    /// Typed at its prompt to quit (sleep).
    var exitCommand: String { get }
    /// Typed at its prompt to start a fresh conversation.
    var newConversationCommand: String { get }
    /// Whether quitting leaves its conversation resumable as it is.
    func canSleep(_ spec: LaunchSpec) -> Bool
    /// The conversation's transcript under an account's config root.
    func transcriptFile(id: String, cwds: [String], root: URL) -> URL?
    /// A transcript's tail as plain lines.
    func renderTranscript(_ text: Substring) -> [String]
    /// Context and limits read after a turn, for CLIs that don't push them (Claude's statusLine does).
    func usage(id: String, root: URL) -> CodexUsage.Reading?
    /// Whether it reports being up on its own (a start hook); otherwise its running process counts.
    var reportsStart: Bool { get }
    /// Whether it reports each submitted prompt (a prompt hook); otherwise a turn starts when work
    /// starts from rest.
    var reportsPrompts: Bool { get }

    // MARK: Accounts

    /// The config root's folder under ~ for the default account.
    var homeFolder: String { get }
    /// The variable pointing it at another account's config root.
    var homeVariable: String { get }
    /// Where conversations live under a config root.
    var historyFolder: String { get }
    /// Signs an account in, in a plain shell.
    var signInCommand: String { get }
    /// Fills a new account's root with the default one's shared settings (never its sign-in).
    func seed(_ directory: URL, from home: URL)
    /// The email an account's root is signed in as; nil when signed out.
    func signedInEmail(home: URL, isDefault: Bool) -> String?

    // MARK: Screen and processes

    /// Lowercased phrases of its folder-trust prompt.
    var trustMarkers: [String] { get }
    /// Lowercased phrases of the screen it shows while signed out.
    var signInMarkers: [String] { get }
    /// The glyph its input line starts with.
    var promptMarker: String { get }
    /// Its approval prompts don't use the question wording `PromptScreen.hasDialog` looks for, so
    /// numbered options alone count as a prompt.
    var optionsAloneMakeDialog: Bool { get }
    /// Whether a process is the CLI itself, by kernel name, executable path, and (for script
    /// interpreters like node) the script it runs.
    func isCLIProcess(name: String, path: String?, script: String?) -> Bool
}

extension SessionKind {
    /// The CLI behind an agent kind; nil for shells, servers and browsers.
    var adapter: AgentAdapter? {
        switch self {
        case .claude: return ClaudeAdapter()
        case .codex: return CodexAdapter()
        case .shell, .server, .browser: return nil
        }
    }

    static var agentAdapters: [AgentAdapter] { allCases.compactMap(\.adapter) }
}

extension AgentAdapter {
    /// Its wrapper in ~/.hyperterm/bin, shell-quoted.
    var wrapper: String { shellQuote(AgentIntegration.binDirectory.appendingPathComponent(command).path) }

    /// An npm install runs `node <script>`: the package's own file, or its bin link named for the command.
    static func isScript(_ script: String?, package: String, command: String) -> Bool {
        guard let script else { return false }
        return script.contains("/\(package)/") || (script as NSString).lastPathComponent == command
    }
}
