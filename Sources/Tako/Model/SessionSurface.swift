import AppKit

/// What a session shows in its tile: a terminal (libghostty) or a browser (Chromium). The store,
/// tiles, and layouts only use this, so a browser is a session like any other.
@MainActor
protocol SessionSurface: NSView {
    var events: TerminalSurfaceEvents? { get set }
    func destroy()
    func sendText(_ text: String)
    func sendReturn()
    func pressKey(named raw: String) -> Bool
    /// What's on screen now: terminal rows, or a browser's title and address.
    func readViewport() -> String
    func readText(lastLines lines: Int) -> String
    func performBinding(_ action: String)
    func setOccluded(_ occluded: Bool)
}

extension TerminalSurfaceView: SessionSurface {}
