import Foundation

/// The last list Sumi was shown: a kill may name only these, so it never reaches a process
/// Sumi guessed at or one that started since.
@MainActor
enum OrphanList {
    static var listed: [pid_t: OrphanProcess] = [:]
}

extension ControlHandler {
    /// Sumi's `orphans`: list what Tako started whose terminal is gone, or stop some of them
    /// once the user asked.
    func orphans(_ request: ControlRequest, reply: @escaping ControlServer.Reply) {
        guard callerSumi != nil else { return reply(.failure("only Sumi stops stray processes")) }
        switch request.text ?? "list" {
        case "list":
            let live = Set(store.sessions.map(\.id.uuidString))
            DispatchQueue.global(qos: .userInitiated).async {
                let found = Orphans.scan(live: live)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        OrphanList.listed = Dictionary(found.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
                    }
                    reply(.success(text: Orphans.describe(found)))
                }
            }
        case "kill":
            switch orphansToKill(request) {
            case .failure(let error):
                reply(.failure(error.description))
            case .success(let chosen):
                Orphans.stop(chosen) {
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { chosen.forEach { OrphanList.listed[$0.pid] = nil } }
                        let left = chosen.filter { SessionReaper.isRunning(TrackedProcess(pid: $0.pid, start: $0.start, session: "")) }
                        let stopped = chosen.filter { !left.contains($0) }.map { "pid \($0.pid)" }
                        var text = stopped.isEmpty ? "" : "stopped " + stopped.joined(separator: ", ") + " (TERM, then KILL)"
                        if !left.isEmpty { text += (text.isEmpty ? "" : "; ") + "still running: " + left.map { "pid \($0.pid)" }.joined(separator: ", ") }
                        reply(left.count == chosen.count ? .failure(text) : .success(text: text))
                    }
                }
            }
        default:
            reply(.failure("orphans takes list or kill"))
        }
    }

    /// The orphans a kill names, all from the last list, once the user asked for it.
    func orphansToKill(_ request: ControlRequest) -> Result<[OrphanProcess], DelegationError> {
        guard request.userRequested == true else {
            return .failure(DelegationError("stopping processes is the user's call: show them the list, and once they say which, "
                + "call kill with those ids and user_requested true"))
        }
        if let refusal = store.userRequestRefusal(true) { return .failure(refusal) }
        let names = request.targets ?? []
        guard !names.isEmpty else { return .failure(DelegationError("pass ids: pids from the last orphans list")) }
        var chosen: [OrphanProcess] = []
        var unknown: [String] = []
        for name in names {
            let digits = name.trimmingCharacters(in: CharacterSet.decimalDigits.inverted)
            guard let pid = pid_t(digits), let orphan = OrphanList.listed[pid] else { unknown.append(name); continue }
            if !chosen.contains(orphan) { chosen.append(orphan) }
        }
        guard unknown.isEmpty else {
            return .failure(DelegationError("\(unknown.joined(separator: ", ")) wasn't in the last orphans list, so nothing was stopped; list again"))
        }
        return .success(chosen)
    }
}
