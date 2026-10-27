import AppKit

@MainActor
enum MainMenu {
    static func build(target: AppDelegate) -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu(target)))
        main.addItem(submenu(sessionMenu(target)))
        main.addItem(submenu(editMenu(target)))
        main.addItem(submenu(viewMenu(target)))
        main.addItem(submenu(goMenu(target)))
        let window = windowMenu()
        main.addItem(submenu(window))
        NSApp.windowsMenu = window
        return main
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func item(_ title: String, _ action: Selector?, _ key: String = "",
                             _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = mods
        item.target = target
        return item
    }

    private static func appMenu(_ target: AppDelegate) -> NSMenu {
        let menu = NSMenu(title: "Tako")
        menu.addItem(item("About Tako", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(AccountsController.showSettings(_:)), ",", target: AccountsController.shared))
        menu.addItem(item("Accounts…", #selector(AccountsController.showAccounts(_:)), target: AccountsController.shared))
        menu.addItem(item("Use ht in Your Shell…", #selector(AppDelegate.installCLI(_:)), target: target))
        let channels = item("Deliver Messages via Claude Channels", #selector(AppDelegate.toggleChannels(_:)), target: target)
        channels.state = SessionStore.channelsEnabled ? .on : .off
        menu.addItem(channels)
        let outsideChrome = item("Let Agents Use My Chrome", #selector(AppDelegate.toggleOutsideChrome(_:)), target: target)
        outsideChrome.state = AgentBrowser.agentsMayUseOutsideChrome ? .on : .off
        outsideChrome.toolTip = "Off: agents browse only in Tako's browsers. On: Claude agents may also use your own Chrome through Claude in Chrome."
        menu.addItem(outsideChrome)
        menu.addItem(.separator())
        menu.addItem(item("Hide Tako", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(.separator())
        menu.addItem(item("Quit Tako", #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private static func sessionMenu(_ target: AppDelegate) -> NSMenu {
        let menu = NSMenu(title: "Terminal")
        menu.addItem(item("New Terminal…", #selector(AppDelegate.newSession(_:)), "n", target: target))
        let quick = item("Quick Ask from Anywhere", #selector(AppDelegate.quickAsk(_:)), target: target)
        quick.toolTip = "⌃⌥Space in any app"
        menu.addItem(quick)
        menu.addItem(item("New Shell Here", #selector(AppDelegate.newShellHere(_:)), "t", target: target))
        menu.addItem(item("New Claude Code Here", #selector(AppDelegate.newClaudeHere(_:)), "c", [.command, .shift], target: target))
        menu.addItem(item("New Codex Here", #selector(AppDelegate.newCodexHere(_:)), "x", [.command, .shift], target: target))
        menu.addItem(item("New Browser", #selector(AppDelegate.newBrowser(_:)), "b", [.command, .shift], target: target))
        menu.addItem(.separator())
        menu.addItem(item("Rename…", #selector(AppDelegate.renameSession(_:)), "r", [.command, .shift], target: target))
        menu.addItem(item("Restart", #selector(AppDelegate.restartSession(_:)), "r", target: target))
        menu.addItem(item("Minimize Tile", #selector(AppDelegate.minimizeTile(_:)), "m", [.command, .shift], target: target))
        let move = NSMenuItem(title: "Move to Account", action: nil, keyEquivalent: "")
        let accounts = NSMenu(title: "Move to Account")
        accounts.delegate = AccountsController.shared
        move.submenu = accounts
        menu.addItem(move)
        menu.addItem(item("Close", #selector(AppDelegate.closeSession(_:)), "w", target: target))
        menu.addItem(.separator())
        menu.addItem(item("Review Changes", #selector(AppDelegate.reviewSelected(_:)), "r", [.command, .option], target: target))
        menu.addItem(item("Fork Conversation", #selector(AppDelegate.forkSelected(_:)), target: target))
        menu.addItem(item("Open in Editor", #selector(AppDelegate.openInEditor(_:)), "o", [.command, .option], target: target))
        menu.addItem(item("Open Preview", #selector(AppDelegate.openPreview(_:)), "o", [.command, .shift], target: target))
        menu.addItem(item("Clean Up Worktrees…", #selector(AppDelegate.cleanUpWorktrees(_:)), target: target))
        return menu
    }

    private static func editMenu(_ target: AppDelegate) -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Copy", #selector(TerminalSurfaceView.copy(_:)), "c"))
        menu.addItem(item("Paste", #selector(TerminalSurfaceView.paste(_:)), "v"))
        menu.addItem(item("Select All", #selector(NSResponder.selectAll(_:)), "a"))
        menu.addItem(.separator())
        menu.addItem(item("Find…", #selector(AppDelegate.find(_:)), "f", target: target))
        menu.addItem(item("Find Next", #selector(AppDelegate.findNext(_:)), "g", target: target))
        menu.addItem(item("Find Previous", #selector(AppDelegate.findPrevious(_:)), "g", [.command, .shift], target: target))
        return menu
    }

    private static func viewMenu(_ target: AppDelegate) -> NSMenu {
        let menu = NSMenu(title: "View")
        menu.addItem(item("Toggle Sidebar", #selector(AppDelegate.toggleSidebarPane(_:)), "s", [.command, .control], target: target))
        menu.addItem(item("Toggle Inspector", #selector(AppDelegate.toggleInspectorPane(_:)), "i", [.command, .option], target: target))
        menu.addItem(item("Toggle Sumi", #selector(AppDelegate.toggleSumi(_:)), "o", [.command, .control], target: target))
        let theme = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        theme.submenu = NSMenu(title: "Theme")
        for option in WindowTheme.allCases {
            let entry = item(option.title, #selector(AppDelegate.chooseWindowTheme(_:)), target: target)
            entry.representedObject = option.rawValue
            entry.state = option == Theme.window ? .on : .off
            theme.submenu?.addItem(entry)
        }
        menu.addItem(theme)
        menu.addItem(.separator())
        menu.addItem(item("Focus", #selector(AppDelegate.layoutFocus(_:)), "1", [.command, .option], target: target))
        menu.addItem(item("Split", #selector(AppDelegate.layoutSplit(_:)), "2", [.command, .option], target: target))
        menu.addItem(item("Grid", #selector(AppDelegate.layoutGrid(_:)), "3", [.command, .option], target: target))
        menu.addItem(item("Zoom Terminal", #selector(AppDelegate.toggleZoom(_:)), "\r", target: target))
        menu.addItem(item("Even Out Tiles", #selector(AppDelegate.evenOutTiles(_:)), "0", [.command, .option], target: target))
        menu.addItem(.separator())
        menu.addItem(item("Bigger", #selector(TerminalSurfaceView.increaseFontSize(_:)), "+"))
        menu.addItem(item("Smaller", #selector(TerminalSurfaceView.decreaseFontSize(_:)), "-"))
        menu.addItem(item("Actual Size", #selector(TerminalSurfaceView.resetFontSize(_:)), "0"))
        menu.addItem(.separator())
        menu.addItem(item("Clear Screen", #selector(TerminalSurfaceView.clearScreen(_:)), "k"))
        return menu
    }

    private static func goMenu(_ target: AppDelegate) -> NSMenu {
        let menu = NSMenu(title: "Go")
        menu.addItem(item("Go to Terminal…", #selector(AppDelegate.showSwitcher(_:)), "p", target: target))
        menu.addItem(item("Next Waiting on You", #selector(AppDelegate.nextWaiting(_:)), "j", target: target))
        menu.addItem(item("Allow Next Request", #selector(AppDelegate.allowNext(_:)), "y", [.command, .option], target: target))
        menu.addItem(item("Deny Next Request", #selector(AppDelegate.denyNext(_:)), "n", [.command, .option], target: target))
        menu.addItem(item("Next Terminal", #selector(AppDelegate.nextSession(_:)), "]", target: target))
        menu.addItem(item("Previous Terminal", #selector(AppDelegate.previousSession(_:)), "[", target: target))
        menu.addItem(.separator())
        for index in 0..<9 {
            let entry = item("Terminal \(index + 1)", #selector(AppDelegate.selectSessionByIndex(_:)), "\(index + 1)", target: target)
            entry.tag = index
            menu.addItem(entry)
        }
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        return menu
    }
}
