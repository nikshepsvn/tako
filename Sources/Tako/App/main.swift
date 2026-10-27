import AppKit
import CCefAppKit

/// Variables that identify a specific agent session. If Tako is launched from inside an
/// agent (e.g. `open` run by Claude Code), every terminal would inherit them and agents started
/// there would think they're child sessions of it.
private func scrubInheritedSessionEnvironment() {
    let exact: Set<String> = ["CLAUDECODE", "CLAUDE_PID", "CLAUDE_EFFORT", "CLAUDE_CODE_ENTRYPOINT",
                              "CLAUDE_CODE_EXECPATH", "CLAUDE_CODE_CHILD_SESSION", "CODEX_THREAD_ID"]
    let prefixes = ["CLAUDE_CODE_SESSION_", "CLAUDE_CODE_MESSAGING_", "CODEX_SANDBOX", "HT_"]
    // HT_HOME picks this instance's data folder (a dev build's), not a session; it stays.
    for key in ProcessInfo.processInfo.environment.keys
    where key != "HT_HOME" && (exact.contains(key) || prefixes.contains(where: key.hasPrefix)) {
        unsetenv(key)
    }
}

scrubInheritedSessionEnvironment()

MainActor.assumeIsolated {
    // Chromium (the browser pane) needs NSApp to be its NSApplication subclass from the first
    // event, even though Chromium itself only starts when a browser is first opened.
    if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
        CEFApplication.install()
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    withExtendedLifetime(delegate) { app.run() }
}
