import Foundation

/// Whether an agent CLI already trusts a folder, read from its own config (never written: the
/// CLI records trust itself once its prompt is answered). Agents started in a folder the CLI
/// doesn't trust stop at "trust this folder?" before any hook runs, which is how four agents sat
/// blocked for 18 minutes; Tako asks the user once instead, up front.
///
/// Errs toward "not trusted": a needless question costs the user one click, while a wrong
/// "trusted" leaves agents stuck. So a parent's trust counts, but the home folder's doesn't
/// (Claude asks again there on every launch) and neither does the root.
enum FolderTrust {
    /// Nil when the kind has no trust prompt Tako knows of.
    @MainActor static func isTrusted(_ folder: String, kind: SessionKind, account: String?) -> Bool? {
        let home = (AccountStore.shared.account(account, kind: kind)
            ?? AgentAccount(id: AgentAccount.defaultID, kind: kind, name: "Default"))
        switch kind {
        case .claude:
            // The default account keeps its state in ~/.claude.json; others in <dir>/.claude.json.
            let file = home.isDefault
                ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
                : home.homeDirectory.appendingPathComponent(".claude.json")
            let json = (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            return claudeTrusts(folder, config: json ?? [:])
        case .codex:
            let text = (try? String(contentsOf: home.homeDirectory.appendingPathComponent("config.toml"), encoding: .utf8)) ?? ""
            return codexTrusts(folder, config: text)
        default:
            return nil
        }
    }

    /// `projects[path].hasTrustDialogAccepted` for the folder or a parent below home.
    static func claudeTrusts(_ folder: String, config: [String: Any], home: String = NSHomeDirectory()) -> Bool {
        let projects = config["projects"] as? [String: Any] ?? [:]
        return candidates(folder, home: home).contains { path in
            (projects[path] as? [String: Any])?["hasTrustDialogAccepted"] as? Bool == true
        }
    }

    /// `[projects."<path>"]` with `trust_level = "trusted"`, for the folder or a parent below home.
    static func codexTrusts(_ folder: String, config: String, home: String = NSHomeDirectory()) -> Bool {
        var trusted = Set<String>()
        var section: String?
        for raw in config.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                section = nil
                if line.hasPrefix("[projects.\""), line.hasSuffix("\"]") {
                    section = String(line.dropFirst("[projects.\"".count).dropLast(2))
                }
            } else if let path = section, line.replacingOccurrences(of: " ", with: "") == "trust_level=\"trusted\"" {
                trusted.insert(path)
            }
        }
        return candidates(folder, home: home).contains(where: trusted.contains)
    }

    /// The folder (as written and with symlinks resolved), then each parent, stopping above home.
    static func candidates(_ folder: String, home: String) -> [String] {
        let home = (home as NSString).standardizingPath
        var result: [String] = []
        for start in Set([standardized(folder), (standardized(folder) as NSString).resolvingSymlinksInPath]) {
            var path = start
            while path != home, path != "/", !path.isEmpty, path.hasPrefix(home + "/") || !start.hasPrefix(home + "/") {
                if !result.contains(path) { result.append(path) }
                let parent = (path as NSString).deletingLastPathComponent
                guard parent != path else { break }
                path = parent
            }
        }
        return result
    }

    static func standardized(_ folder: String) -> String {
        (expandTilde(folder) as NSString).standardizingPath
    }
}
