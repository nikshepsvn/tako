import Foundation

/// Phone Mode: the user is away and steers Tako from their phone through Sumi, so
/// nothing should wait on the Mac. While it's on, Tako approves agents' ordinary permission
/// requests itself, every agent's other waits (questions, risky requests) go to Sumi,
/// and the app's own confirmations are skipped. Risky requests still need the user's yes, given
/// to Sumi on their phone.
extension SessionStore {
    var isPhoneModeOn: Bool { phoneModeSince != nil }

    /// Phone Mode rides on Claude's Remote Control, so it exists only while Claude runs Sumi.
    var phoneModeAvailable: Bool { (sumi?.kind ?? Self.sumiKind) == .claude }

    /// The user's switch: Phone Mode on, and Sumi's session opened to the phone with Remote Control.
    func startPhoneMode() {
        guard phoneModeAvailable else { return }
        setPhoneMode(true)
        if let sumi { sumi.openRemoteControl() } else { remoteControlWhenSumiUp = true }
    }

    /// While Phone Mode is on, Sumi's terminal reads as unfocused to its CLI, so its pushes reach the phone.
    func syncSumiFocusForPhone() {
        (sumi?.surface as? TerminalSurfaceView)?.reportsUnfocused = isPhoneModeOn
    }

    func setPhoneMode(_ on: Bool, now: Date = Date()) {
        defer { syncSumiFocusForPhone() }
        if on {
            guard phoneModeSince == nil else { return }
            phoneModeSince = now
            if sumi == nil, !sumiNeedsChoice { startSumi() }
            addToSumiDigest(SumiEvent(label: "tako", kind: .phoneMode(true)))
            // What's already waiting: ordinary requests are allowed, the rest go to Sumi.
            for session in sessions where adoptIntoPhoneMode(session) {
                guard case .needsInput(let reason) = session.state else { continue }
                if let approval = approvals[session.id], approvesInPhoneMode(session, approval) {
                    _ = answer(session, .approve)
                } else {
                    _ = sumiTakesWait(session, reason: reason, now: now)
                }
            }
        } else {
            guard phoneModeSince != nil else { return }
            phoneModeSince = nil
            for session in sessions where session.delegation?.scope == .phoneMode {
                stopDelegating(session, why: "Phone Mode is off", tellSumi: false)
            }
            addToSumiDigest(SumiEvent(label: "tako", kind: .phoneMode(false)))
        }
    }

    /// Hands an agent's waits to Sumi for as long as Phone Mode lasts; agents started
    /// while it's on are adopted on their first state change. Agents the user handed over with
    /// their own scope keep it. True when it adopted this one.
    @discardableResult
    func adoptIntoPhoneMode(_ session: TerminalSession) -> Bool {
        guard isPhoneModeOn, session.kind.isAgent, !session.isSumi, session.delegation == nil else { return false }
        session.delegation = Delegation(scope: .phoneMode, note: nil)
        session.record(.note, "Sumi handling: while Phone Mode is on")
        return true
    }

    /// Tools whose "permission" is really the agent asking the user something: approving them
    /// unseen would leave the question or plan on a screen nobody is looking at.
    static let asksTheUser: Set<String> = ["AskUserQuestion", "ExitPlanMode"]

    /// Ordinary requests Tako allows itself in Phone Mode: anything Sumi's guard
    /// wouldn't leave for the user, and never a question or a plan.
    func approvesInPhoneMode(_ session: TerminalSession, _ approval: PendingApproval) -> Bool {
        isPhoneModeOn && !session.isSumi && !Self.asksTheUser.contains(approval.toolName)
            && RiskyRequest.reason(tool: approval.toolName, request: approval.request, workspace: session.spec.workPath) == nil
    }

    /// The app's own confirmations (starting servers and agents, closing terminals) have no one to
    /// answer them in Phone Mode; the user asked Sumi from their phone instead.
    func confirmUnlessPhoneMode(_ title: String, _ message: String, completion: @escaping (Bool) -> Void) {
        if isPhoneModeOn { completion(true); return }
        confirm(title, message, completion: completion)
    }
}
