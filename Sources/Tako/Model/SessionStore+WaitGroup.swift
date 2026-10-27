import Foundation

/// wait_for on several terminals at once. `all` replaces a run of single waits with one call;
/// `any` is what single waits can't do without polling: wake on whichever finishes first.
/// Each target still waking it is an ordinary wait tagged with the group, so state changes,
/// output and closes reach it exactly as they reach a single wait; one timer covers the group.
@MainActor
final class WaitGroup {
    enum Mode: String {
        case all, any
    }

    let id = UUID()
    /// Targets in the order the caller named them, which is the order of the reply.
    let order: [UUID]
    let mode: Mode
    let reply: ControlServer.Reply
    var outcomes: [UUID: String] = [:]
    /// The open wait for each target not yet done.
    var members: [UUID: UUID] = [:]
    var finished = false

    init(order: [UUID], mode: Mode, reply: @escaping ControlServer.Reply) {
        self.order = order
        self.mode = mode
        self.reply = reply
    }

    var isSatisfied: Bool { mode == .any ? !outcomes.isEmpty : outcomes.count == order.count }
}

extension SessionStore {
    func startGroupWait(on targets: [TerminalSession], caller: UUID?, goal: AgentWait.Goal, regex: NSRegularExpression?,
                        mode: WaitGroup.Mode, timeout: TimeInterval, reply: @escaping ControlServer.Reply) {
        let group = WaitGroup(order: targets.map(\.id), mode: mode, reply: reply)
        // Targets already there answer at once, as a single wait would.
        for target in targets {
            if let outcome = immediateOutcome(target, goal: goal) { group.outcomes[target.id] = outcome }
        }
        if group.isSatisfied { return finishGroup(group, timedOut: nil) }
        if let refusal = waitCapRefusal(caller) { return reply(refusal) }
        for target in targets where group.outcomes[target.id] == nil {
            let targetID = target.id
            group.members[targetID] = registerWait(on: target, caller: caller, goal: goal, regex: regex, group: group.id) { [weak self] response in
                MainActor.assumeIsolated { self?.groupMemberDone(group, targetID, response.text ?? response.error ?? "") }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            MainActor.assumeIsolated { self?.finishGroup(group, timedOut: timeout) }
        }
    }

    /// Why a wait on `session` is already over, or nil.
    private func immediateOutcome(_ session: TerminalSession, goal: AgentWait.Goal) -> String? {
        guard goal == .output else { return waitOutcome(session, goal: goal) }
        guard case .exited = session.state else { return nil }
        return "@\(session.label) has exited (\(session.state.detail ?? "")); nothing more will print"
    }

    private func groupMemberDone(_ group: WaitGroup, _ target: UUID, _ outcome: String) {
        guard !group.finished else { return }
        group.members[target] = nil
        group.outcomes[target] = outcome
        if group.isSatisfied { finishGroup(group, timedOut: nil) }
    }

    /// One reply: how many are done, then each target's outcome, or its state for those still going.
    private func finishGroup(_ group: WaitGroup, timedOut: TimeInterval?) {
        guard !group.finished else { return }
        group.finished = true
        for wait in group.members.values { agentTools.waits[wait] = nil }
        group.members.removeAll()
        let lines = group.order.map { id in
            group.outcomes[id] ?? "not yet: " + (sessions.first { $0.id == id }.map(describeForWait) ?? "it was closed")
        }
        let head = "\(group.outcomes.count) of \(group.order.count) done" + (timedOut.map { ", timed out after \(Int($0)) s" } ?? "")
        group.reply(.success(text: head + ":\n" + lines.joined(separator: "\n")))
    }
}
