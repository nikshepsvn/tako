import Darwin
import Foundation

/// Tako's own memory. A Jetsam report caught Tako at 1.3–2.0 GB after ~233 hours up, with
/// nothing on screen saying so: the steward measured every agent but not the app hosting them.
/// It now reads its own footprint each tick, shows it with the machine status, and warns once
/// per episode when it crosses `warnBytes`.
struct TakoFootprint {
    /// Past this Tako is worth a restart when convenient; well above a fresh app with a few
    /// dozen terminals (~0.5–1 GB) and below where macOS starts killing it.
    static let warnBytes: UInt64 = 3 << 30
    /// The warning clears only once back under this, so a reading hovering at the line
    /// doesn't raise a new episode every tick.
    static let clearBytes: UInt64 = warnBytes * 4 / 5
    /// The id and label escalations about Tako itself carry.
    static let sessionID = "tako"

    private(set) var bytes: UInt64 = 0
    private(set) var warning: Escalation?

    /// Records a reading; returns the escalation when this one crosses the line.
    mutating func update(_ footprint: UInt64, now: Date) -> Escalation? {
        bytes = footprint
        if warning != nil {
            if footprint < Self.clearBytes { warning = nil } else { warning?.footprintBytes = footprint }
            return nil
        }
        guard footprint >= Self.warnBytes else { return nil }
        let size = ByteCountFormatter.string(fromByteCount: Int64(footprint), countStyle: .memory)
        let escalation = Escalation(sessionID: Self.sessionID, label: Self.sessionID, kind: .takoMemory,
                                    footprintBytes: footprint, cpuPercent: 0, since: now,
                                    message: "Tako itself is using \(size); suggest the user restart Tako when nothing is mid-task")
        warning = escalation
        return escalation
    }

    /// This process's footprint, as Activity Monitor shows it.
    static func current() -> UInt64 { ProcessUsage.read(getpid())?.footprint ?? 0 }
}
