import Foundation

/// Which agent CLIs are on the PATH agents launch with: the user's login shell's, without
/// Tako's own bin folder, whose wrappers always exist.
@MainActor
final class InstalledAgents: ObservableObject {
    static let shared = InstalledAgents()

    /// Nil until the first look finishes.
    @Published private(set) var kinds: Set<SessionKind>?

    /// Unknown counts as installed, so nothing is greyed out while the shell starts.
    func isInstalled(_ kind: SessionKind) -> Bool { kinds?.contains(kind) ?? true }

    func refresh() {
        Task {
            let path = await Task.detached(priority: .userInitiated) { Self.loginPATH() }.value
            kinds = Self.installed(SessionStore.sumiChoices, path: path ?? ProcessInfo.processInfo.environment["PATH"] ?? "",
                                   skipping: AgentIntegration.binDirectory.path,
                                   ControlPaths.legacySupportDirectory.appendingPathComponent("bin").path)
        }
    }

    /// Agents whose command (their raw value) is an executable in a folder on `path`.
    nonisolated static func installed(_ kinds: [SessionKind], path: String, skipping skipped: String...,
                                      isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) -> Set<SessionKind> {
        // Both bin folders: users' PATH lines may still name ~/.hyperterm/bin, a link to ours.
        let skipped = Set(skipped.map { ($0 as NSString).standardizingPath })
        let folders = path.split(separator: ":").map { (String($0) as NSString).standardizingPath }.filter { !skipped.contains($0) }
        return Set(kinds.filter { kind in folders.contains { isExecutable(($0 as NSString).appendingPathComponent(kind.rawValue)) } })
    }

    /// The interactive login shell's PATH, as agents' terminals get it. rc files may print, so
    /// the value follows a marker.
    private nonisolated static func loginPATH() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil } ?? "/bin/zsh"
        let marker = "__KURONAMI_PATH__"
        guard let output = runProcess(shell, ["-lic", "printf '\(marker)%s' \"$PATH\""], timeout: 10),
              let range = output.range(of: marker, options: .backwards) else { return nil }
        return String(output[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
