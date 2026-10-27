import AppKit

/// Code editors the user has installed, for "Open in Editor". Found by bundle identifier, so
/// nothing needs configuring; the last one used becomes the default.
enum Editors {
    struct Editor: Identifiable, Equatable {
        let id: String
        let name: String
    }

    static let known: [Editor] = [
        Editor(id: "com.todesktop.230313mzl4w4u92", name: "Cursor"),
        Editor(id: "com.microsoft.VSCode", name: "Visual Studio Code"),
        Editor(id: "com.microsoft.VSCodeInsiders", name: "VS Code Insiders"),
        Editor(id: "dev.zed.Zed", name: "Zed"),
        Editor(id: "com.exafunction.windsurf", name: "Windsurf"),
        Editor(id: "com.apple.dt.Xcode", name: "Xcode"),
        Editor(id: "com.sublimetext.4", name: "Sublime Text"),
        Editor(id: "com.panic.Nova", name: "Nova"),
        Editor(id: "com.jetbrains.intellij", name: "IntelliJ IDEA"),
        Editor(id: "com.jetbrains.WebStorm", name: "WebStorm"),
        Editor(id: "com.jetbrains.pycharm", name: "PyCharm"),
        Editor(id: "com.jetbrains.goland", name: "GoLand"),
        Editor(id: "com.jetbrains.rustrover", name: "RustRover"),
    ]

    /// Installed editors, the preferred one first.
    static var installed: [Editor] {
        let found = known.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.id) != nil }
        guard let preferred = UserDefaults.standard.string(forKey: "preferredEditor"),
              let index = found.firstIndex(where: { $0.id == preferred }) else { return found }
        var ordered = found
        ordered.insert(ordered.remove(at: index), at: 0)
        return ordered
    }

    static var preferred: Editor? { installed.first }

    static func icon(for editor: Editor) -> NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: editor.id).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    /// Opens `path` (a folder or file) in `editor`, or in the preferred editor, or in Finder.
    static func open(_ path: String, in editor: Editor? = nil) {
        let url = URL(fileURLWithPath: expandTilde(path))
        guard let editor = editor ?? preferred,
              let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: editor.id) else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        UserDefaults.standard.set(editor.id, forKey: "preferredEditor")
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
}
