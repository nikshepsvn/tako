import Foundation

/// Folder trust for the agents Sumi starts, decided once per folder before they launch.
@MainActor
final class StartupGate {
    /// Folders the user said Sumi's agents may work in, though the CLI doesn't trust them yet.
    private(set) var approvedFolders: Set<String> = []
    /// Agents whose trust prompt Tako answers yes, because the user approved their folder.
    private(set) var autoTrust: Set<UUID> = []
    /// Starts waiting on the user's answer for a folder: one question however many start calls ask.
    private var waiting: [String: [(Bool) -> Void]] = [:]
    private var answeredAt: [UUID: Date] = [:]

    func isApproved(_ folder: String) -> Bool { approvedFolders.contains(FolderTrust.standardized(folder)) }
    func approve(_ folder: String) { approvedFolders.insert(FolderTrust.standardized(folder)) }
    func trustOnStart(_ id: UUID) { autoTrust.insert(id) }
    func forget(_ id: UUID) {
        autoTrust.remove(id)
        answeredAt[id] = nil
    }

    /// Asks `ask` once per folder; every call made while that question is open gets its answer.
    func whenAnswered(_ folder: String, ask: (@escaping (Bool) -> Void) -> Void, then: @escaping (Bool) -> Void) {
        let key = FolderTrust.standardized(folder)
        if waiting[key] != nil { waiting[key]?.append(then); return }
        waiting[key] = [then]
        ask { [weak self] approved in
            guard let self else { return }
            if approved { self.approvedFolders.insert(key) }
            let callers = self.waiting.removeValue(forKey: key) ?? []
            callers.forEach { $0(approved) }
        }
    }

    /// Whether to press yes on `id`'s trust prompt now: once every few seconds, as the prompt
    /// can stay drawn for a poll or two after the answer.
    func shouldAnswerTrust(_ id: UUID, now: Date = Date()) -> Bool {
        guard autoTrust.contains(id) else { return false }
        if let last = answeredAt[id], now.timeIntervalSince(last) < 3 { return false }
        answeredAt[id] = now
        return true
    }
}

/// Where a just-started agent got to.
enum StartupOutcome: Equatable {
    case ready
    case waiting(String)
    case exited(String)
    case stillStarting
}

extension SessionStore {
    /// How long start_agent waits by default for its agents to reach their prompt.
    static let startWaitDefault = 25
    static let startWaitMax = 120

    /// The trust prompt of an agent whose folder the user approved: answered yes for them.
    /// TerminalSession calls this from its startup screen poll.
    func trustPromptShown(_ session: TerminalSession) {
        guard startupGate.shouldAnswerTrust(session.id) else { return }
        if case .success = answer(session, .approve) {
            session.record(.note, "Trusted \(abbreviateHome(session.spec.workPath)), as you approved for Sumi's agents")
        }
    }

    /// Where `session` is in its startup, or nil while it is still getting there. A trust prompt
    /// Tako is about to answer isn't a stop.
    func startupOutcome(_ session: TerminalSession) -> StartupOutcome? {
        guard sessions.contains(where: { $0.id == session.id }) else { return .exited("its terminal closed") }
        switch session.state {
        case .exited(let code):
            return .exited(code == 0 ? "the CLI quit" : "exit code \(code)")
        case .failed(let reason):
            return .exited(reason)
        case .needsInput(let reason):
            if reason == TerminalSession.trustReason, startupGate.autoTrust.contains(session.id) { return nil }
            return .waiting(reason)
        case .working, .idle, .running:
            return .ready
        case .starting:
            return session.atRest ? .ready : nil
        }
    }

    /// Polls the agents until each is ready, waiting on a screen, or gone, or `timeout` runs out,
    /// then reports one line per agent. The screen is kept as it goes, so an agent whose
    /// terminal closed still shows its last words.
    func awaitStartup(_ started: [TerminalSession], timeout: TimeInterval, poll: TimeInterval = 0.5,
                      completion: @escaping ([String]) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        var screens: [UUID: String] = [:]
        var outcomes: [UUID: StartupOutcome] = [:]
        func step() {
            for session in started where outcomes[session.id] == nil {
                if sessions.contains(where: { $0.id == session.id }) {
                    let screen = session.surface.readViewport()
                    if !screen.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { screens[session.id] = screen }
                }
                if let outcome = startupOutcome(session) { outcomes[session.id] = outcome }
            }
            if outcomes.count < started.count, Date() < deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + poll) { step() }
                return
            }
            completion(started.map { session in
                Self.describeStartup(session.label, outcomes[session.id] ?? .stillStarting,
                                     screen: screens[session.id], waited: Int(timeout.rounded()))
            })
        }
        step()
    }

    static func describeStartup(_ label: String, _ outcome: StartupOutcome, screen: String?, waited: Int) -> String {
        func tail() -> String {
            let lines = (screen ?? "").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return lines.isEmpty ? "" : "\n    last lines: " + lines.suffix(6).joined(separator: " ⏎ ")
        }
        switch outcome {
        case .ready:
            return "@\(label): ready"
        case .waiting(let reason) where reason == TerminalSession.trustReason:
            return "@\(label): waiting on \(reason) Ask the user, then trust_folder with user_approved true"
        case .waiting(let reason):
            return "@\(label): waiting on \(reason) (read_terminal it; answer with choose_option or ask the user)"
        case .exited(let why):
            return "@\(label): exited: \(why)" + tail()
        case .stillStarting:
            return "@\(label): still starting after \(waited) s; Tako tells you if it fails or waits" + tail()
        }
    }
}
