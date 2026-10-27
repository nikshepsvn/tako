import AppKit

/// The sidebar footer's Run menu: the selected session's project actions (tests, dev server,
/// build), rebuilt each time it opens.
@MainActor
final class ProjectActionsMenu: NSObject, NSMenuDelegate {
    private let store: SessionStore
    private let menu = NSMenu(title: "Actions")

    init(store: SessionStore) {
        self.store = store
        super.init()
        menu.delegate = self
    }

    /// Opens under the pointer, where the Run button was just clicked.
    func popUp() {
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let actions = store.projectActions(for: store.selected)
        if actions.isEmpty {
            let empty = NSMenuItem(title: store.selected == nil ? "Select a session first" : "No actions for this project", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for (index, action) in actions.enumerated() {
            let item = NSMenuItem(title: action.name, action: #selector(runAction(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)
            item.toolTip = action.command
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let help = NSMenuItem(title: "Add actions in .hyperterm.json", action: nil, keyEquivalent: "")
        help.isEnabled = false
        menu.addItem(help)
    }

    @objc private func runAction(_ sender: NSMenuItem) {
        guard let session = store.selected else { return }
        let actions = store.projectActions(for: session)
        guard actions.indices.contains(sender.tag) else { return }
        store.run(actions[sender.tag], for: session)
    }
}
