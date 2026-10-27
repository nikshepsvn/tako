import Foundation

/// Sumi's board and memory tools. The caller is checked to be Sumi before this runs; each tool's
/// arguments arrive as the JSON the model wrote, so a new field needs no wire change.
extension ControlHandler {
    func handleSumi(_ request: ControlRequest, reply: @escaping ControlServer.Reply) {
        let args = (request.payload.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any]) ?? [:]
        func send(_ result: Result<String, PlanError>) {
            switch result {
            case .success(let text): reply(.success(text: text))
            case .failure(let error): reply(.failure(error.description))
            }
        }
        switch request.text {
        case "standup":
            let only = (args["terminals"] as? [String]).flatMap { $0.isEmpty ? nil : $0 }
            let since = (args["since"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            store.standup(only: only, since: since) { reply(.success(text: $0)) }
        case "plan":
            send(store.planCommand(args))
        case "remember":
            send(store.rememberCommand(args))
        case "doctor":
            store.doctor { reply(.success(text: $0)) }
        case "recall":
            reply(.success(text: store.recall(project: args["project"] as? String)))
        case "peer":
            store.peerCommand(args) { send($0) }
        default:
            reply(.failure("unknown Sumi tool \(request.text ?? "")"))
        }
    }
}
