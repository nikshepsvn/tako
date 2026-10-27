import AppKit
import Combine

/// Menu bar item: how many agents are waiting on you, from anywhere on the Mac. The menu lists
/// every agent with its state; picking one brings Tako forward on it.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let store: SessionStore
    private var cancellable: AnyCancellable?

    init(store: SessionStore) {
        self.store = store
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        cancellable = store.objectWillChange
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
        refresh()
    }

    private func refresh() {
        guard let button = item.button else { return }
        let waiting = store.attentionCount
        let working = store.sessions.filter { $0.state == .working }.count
        let symbol = waiting > 0 ? "exclamationmark.bubble.fill" : working > 0 ? "fish.fill" : "fish"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Tako")
        button.image?.isTemplate = true
        button.imagePosition = .imageLeading
        button.title = waiting > 0 ? " \(waiting)" : ""
        button.toolTip = "\(waiting) waiting · \(working) working"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let agents = store.projects.flatMap(\.agents)
        if agents.isEmpty {
            menu.addItem(NSMenuItem(title: "No agents running", action: nil, keyEquivalent: ""))
        }
        for session in agents {
            let title = "@\(session.label) — \(session.state.phrase)"
            let entry = NSMenuItem(title: title, action: #selector(open(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = session.id
            if let line = session.state.needsAttention ? session.pendingRequest ?? session.state.detail : session.agentStatus ?? session.summary {
                entry.toolTip = line
            }
            entry.image = NSImage(systemSymbolName: session.state.needsAttention ? "circle.fill" : "circle", accessibilityDescription: nil)
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        let show = NSMenuItem(title: "Open Tako", action: #selector(activate), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
    }

    @objc private func open(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let session = store.sessions.first(where: { $0.id == id }) else { return }
        activate()
        store.select(session)
    }

    @objc private func activate() {
        NSApp.activate(ignoringOtherApps: true)
        // The main window, even when its close button hid it.
        NSApp.windows.first { $0.delegate is MainWindowController }?.makeKeyAndOrderFront(nil)
    }
}
