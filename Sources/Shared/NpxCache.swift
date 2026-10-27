import Foundation

/// `npx -y pkg@1.2.3 args…` run as `node <its bin> args…` when npx has already downloaded that
/// exact version. npx otherwise stays running as the server's parent (`npm exec`, ~80 MB per
/// server per agent) and asks the registry on every start.
enum NpxCache {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".npm/_npx")
    }

    /// The direct `node` command, or nil to keep the original: not npx, a version range or tag
    /// (`@latest` may have moved on since the download), npx options other than -y, or no copy.
    static func directCommand(_ command: [String], cache: URL = directory) -> [String]? {
        guard let program = command.first, (program as NSString).lastPathComponent == "npx" else { return nil }
        var rest = command.dropFirst()
        while let flag = rest.first, flag.hasPrefix("-") {
            guard ["-y", "--yes", "-q", "--quiet"].contains(flag) else { return nil }
            rest = rest.dropFirst()
        }
        guard let spec = rest.first, let (name, version) = pinned(spec),
              let script = cachedBin(name: name, version: version, cache: cache) else { return nil }
        return ["node", script] + rest.dropFirst()
    }

    /// "pkg@1.2.3" or "@scope/pkg@1.2.3-beta.1" → (name, version); nil without an exact version.
    static func pinned(_ spec: String) -> (name: String, version: String)? {
        guard let at = spec.lastIndex(of: "@"), at != spec.startIndex else { return nil }
        let name = String(spec[..<at]), version = String(spec[spec.index(after: at)...])
        let core = version.split(separator: "-", maxSplits: 1).first.map(String.init) ?? ""
        let numbers = core.split(separator: ".", omittingEmptySubsequences: false)
        guard !name.isEmpty, numbers.count == 3, numbers.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        return (name, version)
    }

    /// The package's entry script in npx's cache, for exactly `version`.
    static func cachedBin(name: String, version: String, cache: URL) -> String? {
        let entries = (try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)) ?? []
        for entry in entries.sorted(by: { $0.path < $1.path }) {
            let package = entry.appendingPathComponent("node_modules/\(name)")
            guard let data = try? Data(contentsOf: package.appendingPathComponent("package.json")),
                  let manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  manifest["version"] as? String == version,
                  let bin = binPath(manifest["bin"], name: name) else { continue }
            let script = package.appendingPathComponent(bin).standardizedFileURL.path
            if FileManager.default.isReadableFile(atPath: script) { return script }
        }
        return nil
    }

    /// npx runs the bin named after the package (without its scope), or the only one there is.
    private static func binPath(_ bin: Any?, name: String) -> String? {
        if let single = bin as? String { return single }
        guard let bins = bin as? [String: String] else { return nil }
        let short = (name as NSString).lastPathComponent
        return bins[short] ?? (bins.count == 1 ? bins.values.first : nil)
    }
}
