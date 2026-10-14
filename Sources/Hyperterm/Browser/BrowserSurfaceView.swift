import AppKit
import CefSwiftUI
import Observation
import SwiftUI

/// A browser session's tile content: the address bar and its own Chromium page. Every browser
/// shares one profile, so logins carry across them.
@MainActor
final class BrowserSurfaceView: NSView, SessionSurface {
    weak var events: TerminalSurfaceEvents?
    let model: CefWebViewModel
    /// The session's label: tags the page so agents' tools can tell browsers apart.
    var label: String {
        didSet {
            host?.rootView = pane()
            mark()
        }
    }
    private let store: SessionStore
    /// Chromium and this page start only once the tile is on screen or an agent asks for it,
    /// so restored browsers nobody is looking at cost nothing.
    private(set) var isLive = false
    /// Called with the page's address and title as they change, to persist and show them.
    var onNavigate: ((URL?, String) -> Void)?
    private var host: NSHostingView<BrowserPane>?
    private var destroyed = false
    private var lastSearch = ""

    init(url: URL?, label: String, store: SessionStore) {
        self.model = CefWebViewModel(url: url ?? URL(string: "about:blank"))
        self.label = label
        self.store = store
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let pane = NSHostingView(rootView: pane())
        pane.sizingOptions = []
        pane.autoresizingMask = [.width, .height]
        pane.frame = bounds
        addSubview(pane)
        host = pane
        observeModel()
    }

    private func pane() -> BrowserPane {
        BrowserPane(browser: AgentBrowser.shared, model: model, label: label, store: store, isLive: isLive)
    }

    /// Last time the user looked at it or an agent used it; hidden browsers idle past a limit sleep.
    private(set) var lastUsedAt = Date()

    func noteUse() { lastUsedAt = Date() }

    /// Hidden and nobody's: SwiftUI drops the Chromium view, which closes the page and its
    /// renderer. The address stays on the model, so goLive reopens it where it was.
    func goDormant() {
        guard isLive, !destroyed else { return }
        isLive = false
        host?.rootView = pane()
    }

    /// Off screen: not in a window, or its tile is hidden.
    var isOffScreen: Bool { window == nil || isHiddenOrHasHiddenAncestor }

    /// Starts Chromium if needed and creates the page, even while the tile is hidden (an agent
    /// can use a browser nobody is looking at).
    func goLive() {
        noteUse()
        guard !isLive, !destroyed else { return }
        isLive = true
        AgentBrowser.shared.start()
        host?.rootView = pane()
        // Chromium creates the page once its view is laid out in a window; hidden tiles don't
        // lay out on their own.
        if window != nil { host?.layoutSubtreeIfNeeded() }
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        if isLive {
            host?.layoutSubtreeIfNeeded()
        } else if !isHiddenOrHasHiddenAncestor {
            goLive()
        }
    }

    /// Sent when this view or an ancestor (its tile) is unhidden: the user is now looking at it.
    override func viewDidUnhide() {
        super.viewDidUnhide()
        if window != nil, !isHiddenOrHasHiddenAncestor { goLive() }
    }

    // MARK: Page tag

    /// Agents' tools find "their" page by this tag, so it's set again after every load.
    func mark() {
        model.executeJavaScript("window.__hyperterm = '\(label)'")
    }

    private func observeModel() {
        withObservationTracking {
            _ = (model.url, model.title, model.isLoading)
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !self.destroyed else { return }
                    self.onNavigate?(self.model.url, self.model.title)
                    if !self.model.isLoading { self.mark() }
                    self.observeModel()
                }
            }
        }
    }

    // MARK: SessionSurface

    func destroy() {
        destroyed = true
        model.browser?.close(force: true)
        // Drop the Chromium view now rather than whenever SwiftUI gets to it, so its page closes
        // with the tile (BrowserJanitor sweeps up any that linger anyway).
        isLive = false
        host?.rootView = pane()
    }

    /// Typing into a page goes through the agent's browser tools, not the terminal channel.
    func sendText(_ text: String) {}
    func sendReturn() {}
    func pressKey(named raw: String) -> Bool { false }

    func readViewport() -> String {
        [model.title, model.url?.absoluteString ?? ""].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    func readText(lastLines lines: Int) -> String { readViewport() }

    func performBinding(_ action: String) {
        if action.hasPrefix("search:") {
            lastSearch = String(action.dropFirst("search:".count))
            if !lastSearch.isEmpty { model.browser?.find(lastSearch, forward: true, matchCase: false) }
        } else if action.hasPrefix("navigate_search:"), !lastSearch.isEmpty {
            model.browser?.find(lastSearch, forward: action.hasSuffix("next"), matchCase: false)
        }
    }

    func setOccluded(_ occluded: Bool) {}
}
