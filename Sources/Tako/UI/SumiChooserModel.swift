import Foundation

/// The rules for telling whether Sumi started.
@MainActor
enum SumiOnboarding {
    /// How long after a start Sumi that dies still counts as one that failed to start.
    static let startWindow: TimeInterval = 10

    enum StartVerdict: Equatable { case waiting, started, failed }

    /// `exited` is nil when there is no sumi session; `launching` is true while Tako is still starting one.
    static func startVerdict(exited: Bool?, launching: Bool, elapsed: TimeInterval) -> StartVerdict {
        switch exited {
        case true?: return .failed
        case false?: return elapsed >= startWindow ? .started : .waiting
        case nil: return launching ? .waiting : .failed
        }
    }

    static func failureMessage(kind: SessionKind, modelTitle: String) -> String {
        "\(kind.displayName) couldn't start with \(modelTitle)."
    }
}
