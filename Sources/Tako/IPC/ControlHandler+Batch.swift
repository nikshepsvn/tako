import Foundation

/// One Sumi call for many terminals: "stop all the duaa ones" or "kill all of it and restart
/// them" took a call (or three) per agent. Each terminal gets its own line, so one refusal
/// doesn't hide what happened to the rest.
extension ControlHandler {
    static let batchActions: Set<String> = ["choose", "interrupt", "restart"]

    func actOnMany(_ request: ControlRequest, reply: @escaping ControlServer.Reply) {
        guard Self.batchActions.contains(request.text ?? "") else {
            reply(.failure("only restart_agent, interrupt_agent and choose_option take several terminals"))
            return
        }
        runBatch(request, reply: reply) { target, done in actForSumi(on: target, request, completion: done) }
    }

    func closeMany(_ request: ControlRequest, reply: @escaping ControlServer.Reply) {
        runBatch(request, reply: reply) { target, done in closeForSumi(target, request, completion: done) }
    }

    /// Resolves the names (labels, globs, "all"), runs `action` on each at once, and replies once
    /// all have answered: success when any did, with every terminal's result.
    private func runBatch(_ request: ControlRequest, reply: @escaping ControlServer.Reply,
                          action: (TerminalSession, @escaping (Result<String, DelegationError>) -> Void) -> Void) {
        let names = (request.targets ?? []) + [request.target].compactMap { $0 }.filter { !$0.isEmpty }
        let (targets, unknown) = store.sessions(matching: names)
        guard !targets.isEmpty else {
            reply(notFound(names.joined(separator: ", ")))
            return
        }
        let results = BatchResults(labels: targets.map(\.label), unknown: unknown)
        for (index, target) in targets.enumerated() {
            action(target) { result in
                guard results.record(index, result) else { return }
                reply(results.response)
            }
        }
    }
}

/// Per-terminal results of a batch, filled as each answers (on the main queue).
final class BatchResults {
    private let labels: [String]
    private let unknown: [String]
    private var results: [Int: Result<String, DelegationError>] = [:]

    init(labels: [String], unknown: [String]) {
        self.labels = labels
        self.unknown = unknown
    }

    /// True once every terminal has answered.
    func record(_ index: Int, _ result: Result<String, DelegationError>) -> Bool {
        results[index] = result
        return results.count == labels.count
    }

    var response: ControlResponse {
        var lines: [String] = []
        var succeeded = 0
        for (index, label) in labels.enumerated() {
            switch results[index] {
            case .success(let text):
                succeeded += 1
                // Each action returns the screen after; a batch keeps just what was done.
                lines.append("@\(label): " + (text.split(separator: "\n").first.map(String.init) ?? "done"))
            case .failure(let error):
                lines.append("@\(label): refused: \(error.description)")
            case nil:
                lines.append("@\(label): no answer")
            }
        }
        lines += unknown.map { "\($0): no terminal by that name or pattern" }
        let text = "\(succeeded) of \(labels.count) done\n" + lines.joined(separator: "\n")
        return succeeded > 0 ? .success(text: text) : .failure(text)
    }
}
