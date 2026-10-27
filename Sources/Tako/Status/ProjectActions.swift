import Foundation

/// A one-click command for a project: run the tests, start Storybook, lint. Declared in
/// `.hyperterm.json` under "actions", or detected from the project's own manifests when none
/// are declared.
struct ProjectAction: Codable, Equatable, Identifiable {
    var name: String
    var command: String
    /// SF Symbol name; a sensible default is picked from the name.
    var icon: String?
    /// Long-running commands (dev servers, watchers) open as servers on the shelf; others run
    /// in a shell tile that stays open with the output.
    var server: Bool?

    var id: String { name + "\u{0}" + command }

    var symbol: String {
        if let icon, !icon.isEmpty { return icon }
        let lower = name.lowercased()
        if lower.contains("test") { return "checkmark.diamond" }
        if lower.contains("lint") || lower.contains("format") { return "wand.and.stars" }
        if lower.contains("build") { return "hammer" }
        if lower.contains("dev") || lower.contains("start") || lower.contains("serve") { return "play" }
        if lower.contains("deploy") || lower.contains("release") { return "paperplane" }
        if lower.contains("storybook") { return "book" }
        return "terminal"
    }

    var isServer: Bool {
        if let server { return server }
        let lower = name.lowercased()
        return ["dev", "start", "serve", "watch", "storybook"].contains { lower.contains($0) }
    }

    // MARK: - Detection

    /// Actions inferred from the files at `root`, in a stable order: dev, test, build, lint.
    static func detect(at root: String) -> [ProjectAction] {
        let fm = FileManager.default
        func has(_ name: String) -> Bool { fm.fileExists(atPath: (root as NSString).appendingPathComponent(name)) }
        func text(_ name: String) -> String? {
            try? String(contentsOfFile: (root as NSString).appendingPathComponent(name), encoding: .utf8)
        }

        if let data = text("package.json")?.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let scripts = json["scripts"] as? [String: Any] {
            let runner = has("pnpm-lock.yaml") ? "pnpm" : has("bun.lockb") || has("bun.lock") ? "bun"
                : has("yarn.lock") ? "yarn" : "npm run"
            let preferred = ["dev", "start", "test", "build", "lint", "typecheck", "format", "storybook"]
            return preferred.filter { scripts[$0] != nil }.prefix(6).map {
                ProjectAction(name: $0.capitalized, command: "\(runner) \($0)")
            }
        }
        if has("Cargo.toml") {
            return [ProjectAction(name: "Build", command: "cargo build"), ProjectAction(name: "Test", command: "cargo test"),
                    ProjectAction(name: "Lint", command: "cargo clippy")]
        }
        if has("Package.swift") {
            return [ProjectAction(name: "Build", command: "swift build"), ProjectAction(name: "Test", command: "swift test")]
        }
        if has("go.mod") {
            return [ProjectAction(name: "Build", command: "go build ./..."), ProjectAction(name: "Test", command: "go test ./...")]
        }
        if has("pyproject.toml") || has("pytest.ini") {
            return [ProjectAction(name: "Test", command: "pytest")]
        }
        if let makefile = text("Makefile") {
            let targets = makefile.split(separator: "\n").compactMap { line -> String? in
                guard let colon = line.firstIndex(of: ":"), !line.hasPrefix("\t"), !line.hasPrefix("."),
                      !line[line.index(after: colon)...].hasPrefix("=") else { return nil }
                let name = line[..<colon].trimmingCharacters(in: .whitespaces)
                return name.range(of: "^[a-zA-Z][a-zA-Z0-9_-]*$", options: .regularExpression) != nil ? name : nil
            }
            return Array(targets.prefix(5)).map { ProjectAction(name: $0.capitalized, command: "make \($0)") }
        }
        return []
    }
}
