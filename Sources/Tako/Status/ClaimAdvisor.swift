import Foundation

/// Advisory file claims at edit time. Claims never block an edit: an agent about to edit a path
/// another agent claimed on the team board gets a one-line heads-up in its PreToolUse hook reply,
/// and the edit goes ahead. Claude's hooks are answered on the hook listener's own threads,
/// before the store sees the event, so they're checked against `ClaimIndex`, a lock-guarded copy
/// of the boards' claims. With no claims anywhere the check is one locked read: nothing is
/// parsed and the reply is the same empty 200 as before.

/// The edits a PreToolUse payload is about to make.
enum EditHook {
    static let tools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit", "apply_patch"]

    /// Paths as the tool names them (absolute, or relative to the hook's cwd); empty for any
    /// other event or tool.
    static func paths(_ json: [String: Any]) -> [String] {
        guard json["hook_event_name"] as? String == "PreToolUse",
              let tool = json["tool_name"] as? String, tools.contains(tool) else { return [] }
        let input = json["tool_input"] as? [String: Any] ?? [:]
        if let path = (input["file_path"] ?? input["notebook_path"]) as? String, !path.isEmpty { return [path] }
        // Codex's apply_patch carries the patch itself; its file headers name the paths.
        return input.values.compactMap { $0 as? String }.flatMap(patchPaths)
    }

    private static let patchHeaders = ["*** Update File: ", "*** Add File: ", "*** Delete File: ", "*** Move to: "]

    static func patchPaths(_ patch: String) -> [String] {
        var paths: [String] = []
        for line in patch.split(whereSeparator: \.isNewline) {
            guard let header = patchHeaders.first(where: { line.hasPrefix($0) }) else { continue }
            let path = line.dropFirst(header.count).trimmingCharacters(in: .whitespaces)
            if !path.isEmpty, !paths.contains(path) { paths.append(path) }
        }
        return paths
    }

    /// The hook reply that adds `text` to the agent's context. It carries no permission
    /// decision, so the CLI's own prompt rules still apply. Claude Code and Codex (0.160) read
    /// the same shape.
    static func reply(_ text: String) -> Data {
        let output = ["hookSpecificOutput": ["hookEventName": "PreToolUse", "additionalContext": text]]
        return (try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])) ?? Data()
    }

    /// One line for the editor: whose claim, and what to do about it.
    static func headsUp(_ hits: [ClaimIndex.Hit]) -> String {
        let named = hits.map { "\($0.path) is in @\($0.claim.ownerLabel)'s claim \($0.claim.path)" }
        let holders = Array(Set(hits.map { "@" + $0.claim.ownerLabel })).sorted().joined(separator: ", ")
        return "Tako team board: " + named.joined(separator: "; ")
            + ". The edit goes ahead and \(holders) was told; coordinate via send_message or team_board."
    }
}

/// Who holds which paths, by project, and where each agent's workspace is: everything an edit
/// check needs, readable from any thread.
final class ClaimIndex: @unchecked Sendable {
    struct Workspace: Equatable {
        /// The project's main checkout, the board's key.
        let project: String
        /// The agent's own checkout, which claimed paths are relative to.
        let root: String
    }

    /// An edit inside someone else's claim.
    struct Hit: Equatable {
        let claim: FileClaim
        /// The edited path, relative to the project.
        let path: String
    }

    /// An editor hears about a claim, and its holder about the editor, once in this long.
    static let repeatInterval: TimeInterval = 600

    private let lock = NSLock()
    private var claims: [String: [FileClaim]] = [:]
    private var workspaces: [UUID: Workspace] = [:]
    private var warned: [String: Date] = [:]

    var isEmpty: Bool { lock.withLock { claims.isEmpty } }

    /// Replaces the claims: the boards' live claims by project. Workspaces are dropped once no
    /// claim is left, so an idle index holds nothing.
    func setClaims(_ byProject: [String: [FileClaim]]) {
        lock.withLock {
            claims = byProject.filter { !$0.value.isEmpty }
            if claims.isEmpty {
                workspaces.removeAll()
                warned.removeAll()
            }
        }
    }

    /// Records where an agent works. Returns whether that changed.
    @discardableResult
    func register(_ id: UUID, _ workspace: Workspace?) -> Bool {
        lock.withLock {
            guard workspaces[id] != workspace else { return false }
            workspaces[id] = workspace
            return true
        }
    }

    func workspace(of id: UUID) -> Workspace? { lock.withLock { workspaces[id] } }

    /// Other agents' live claims covering `paths`, each claim reported to an editor once per
    /// `repeatInterval`. Paths outside the editor's workspace are skipped.
    func hits(editor: UUID, paths: [String], cwd: String?, now: Date = Date()) -> [Hit] {
        lock.withLock {
            guard let workspace = workspaces[editor], let held = claims[workspace.project] else { return [] }
            warned = warned.filter { now.timeIntervalSince($0.value) < Self.repeatInterval }
            var hits: [Hit] = []
            for raw in paths {
                let absolute = raw.hasPrefix("/") ? raw : ((cwd ?? workspace.root) as NSString).appendingPathComponent(raw)
                guard let path = ClaimPath.normalize(absolute, root: workspace.root) else { continue }
                for claim in held where claim.owner != editor && claim.expires > now && ClaimPath.overlaps(claim.path, path) {
                    let key = "\(editor)|\(claim.owner)|\(claim.path)"
                    guard warned[key] == nil else { continue }
                    warned[key] = now
                    hits.append(Hit(claim: claim, path: path))
                }
            }
            return hits
        }
    }

    /// The heads-up for one hook payload, or nil when it edits nothing someone else claimed.
    /// Cheap when unused: no claims means no parse.
    func advise(editor: UUID, payload: Data, now: Date = Date()) -> (reply: Data, hits: [Hit])? {
        guard !isEmpty, payload.range(of: Data("PreToolUse".utf8)) != nil,
              let json = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] else { return nil }
        let paths = EditHook.paths(json)
        guard !paths.isEmpty else { return nil }
        let hits = hits(editor: editor, paths: paths, cwd: json["cwd"] as? String, now: now)
        guard !hits.isEmpty else { return nil }
        return (EditHook.reply(EditHook.headsUp(hits)), hits)
    }
}
