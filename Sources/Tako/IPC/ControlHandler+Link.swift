import Foundation

/// `ht link`: Tako Link from the command line, for the user and scripts/link-smoke.sh. The same
/// actions as Settings › Link and the Sumi dock's approval cards; only the user may use them
/// (an agent confirming a pairing or approving its own message would defeat the point).
extension ControlHandler {
    func link(_ request: ControlRequest) -> ControlResponse {
        let link = store.link
        let label = request.label?.trimmingCharacters(in: .whitespaces) ?? ""
        switch request.text ?? "status" {
        case "status":
            return .success(text: linkStatusJSON())
        case "on", "off":
            link.setEnabled(request.text == "on")
            return .success(text: "Tako Link \(request.text ?? "")")
        case "name":
            guard !label.isEmpty else { return .failure("usage: ht link name <display name>") }
            link.setName(label)
            return .success(text: "shown as \(link.displayName)")
        case "pair":
            let wanted = label.lowercased()
            guard let nearby = link.nearby.first(where: { $0.name.lowercased() == wanted || $0.fingerprint.hasPrefix(wanted) && !wanted.isEmpty }) else {
                return .failure("no Tako nearby named \(label); nearby: \(link.nearby.map(\.name).joined(separator: ", "))")
            }
            guard !link.isPairingBusy else { return .failure("a pairing is already in progress") }
            link.pair(with: nearby)
            return .success(text: "pairing with \(nearby.name); compare codes with ht link status")
        case "confirm":
            guard link.pairing?.phase == .comparing else { return .failure("no code to confirm yet") }
            link.confirmPairing()
            return .success(text: "confirmed")
        case "cancel":
            link.cancelPairing()
            return .success(text: "cancelled")
        case "unpair":
            guard let peer = link.peer(named: label) else { return .failure("no paired peer named \(label)") }
            link.unpair(peer)
            return .success(text: "unpaired \(peer.name)")
        case "approve":
            if let error = store.approveLink(label, text: request.payload) { return .failure(error) }
            return .success(text: "sending")
        case "deny":
            store.denyLink(label)
            return .success(text: "denied")
        default:
            return .failure("ht link: status, on, off, name, pair, confirm, cancel, unpair, approve or deny")
        }
    }

    /// Everything Settings and the dock show, as JSON for scripts.
    private func linkStatusJSON() -> String {
        let link = store.link
        var pairing: [String: Any]?
        if let current = link.pairing {
            let phase: String
            switch current.phase {
            case .connecting: phase = "connecting"
            case .comparing: phase = "comparing"
            case .waitingForPeer: phase = "waiting"
            case .paired: phase = "paired"
            case .failed(let why): phase = "failed: " + why
            }
            pairing = ["name": current.name, "code": current.code ?? "", "phase": phase, "incoming": current.incoming]
        }
        let object: [String: Any] = [
            "enabled": link.settings.enabled,
            "status": link.status,
            "name": link.displayName,
            "fingerprint": link.identity.fingerprint,
            "port": link.port.map { Int($0) } ?? 0,
            "nearby": link.nearby.map { ["name": $0.name, "fingerprint": $0.fingerprint] },
            "peers": link.peers.map { ["name": $0.name, "fingerprint": $0.fingerprint, "online": link.isOnline($0)] },
            "pairing": pairing ?? NSNull(),
            "approvals": link.approvals.map { ["id": $0.id, "peer": $0.peer.name, "kind": $0.message.kind.rawValue, "text": $0.message.text ?? ""] },
            "inbox": link.inbox.map { ["peer": $0.peerName, "kind": $0.kind.rawValue, "text": $0.text, "incoming": $0.incoming,
                                       "request_id": $0.requestID ?? ""] },
            "undelivered": link.undelivered.count,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
