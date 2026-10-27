import AppKit
import WebKit

/// A dev server's page in a native window next to its terminal: reload, back, open in browser.
@MainActor
final class PreviewWindowController: NSWindowController, NSToolbarDelegate, WKNavigationDelegate {
    private let webView = WKWebView()
    private static var open: [Int: PreviewWindowController] = [:]

    static func show(port: Int) {
        if let existing = open[port] {
            existing.showWindow(nil)
            existing.webView.reload()
            return
        }
        let controller = PreviewWindowController(port: port)
        open[port] = controller
        controller.showWindow(nil)
    }

    private let port: Int

    private init(port: Int) {
        self.port = port
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "localhost:\(port)"
        window.toolbarStyle = .unifiedCompact
        super.init(window: window)
        window.contentView = webView
        webView.navigationDelegate = self
        let toolbar = NSToolbar(identifier: "Preview")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.setFrameAutosaveName("TakoPreview")
        window.center()
        if let url = URL(string: "http://localhost:\(port)") { webView.load(URLRequest(url: url)) }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { PreviewWindowController.open[port] = nil }
        }
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            window?.subtitle = webView.title ?? ""
        }
    }

    @objc private func reload(_ sender: Any?) { webView.reload() }
    @objc private func goBack(_ sender: Any?) { webView.goBack() }
    @objc private func openExternally(_ sender: Any?) {
        if let url = webView.url { NSWorkspace.shared.open(url) }
    }

    private static let back = NSToolbarItem.Identifier("back")
    private static let reloadID = NSToolbarItem.Identifier("reload")
    private static let external = NSToolbarItem.Identifier("external")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.back, Self.reloadID, .flexibleSpace, Self.external]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.isBordered = true
        item.target = self
        switch identifier {
        case Self.back:
            item.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")
            item.action = #selector(goBack(_:))
        case Self.reloadID:
            item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Reload")
            item.action = #selector(reload(_:))
        case Self.external:
            item.image = NSImage(systemSymbolName: "safari", accessibilityDescription: "Open in Browser")
            item.action = #selector(openExternally(_:))
        default:
            return nil
        }
        return item
    }
}
