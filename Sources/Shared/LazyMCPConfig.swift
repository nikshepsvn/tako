import CryptoKit
import Foundation

/// The user's own stdio MCP servers, rewritten so each agent starts its own copy through
/// `ht mcp-lazy` on first use instead of at launch. The user's config files are only read.
enum LazyMCP {
    /// Names Tako's own MCP servers already use. "hyperterm" was the main server's name before
    /// the rename, and Claude channels registered it under that name in the user's config, so a
    /// server called that is ours too and must never shadow `tako`.
    static let reservedNames: Set<String> = ["tako", "hyperterm", "browser"]

    static var cacheDirectory: URL {
        ControlPaths.supportDirectory.appendingPathComponent("mcp-cache", isDirectory: true)
    }

    /// One cache per server: its command, arguments and the values of its configured env.
    static func cacheKey(command: String, arguments: [String], environment: [String: String]) -> String {
        let parts = [command] + arguments + environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        let data = (try? JSONSerialization.data(withJSONObject: parts)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func proxyArguments(name: String, command: String, arguments: [String], envKeys: [String]) -> [String] {
        var args = ["mcp-lazy", "--name", name]
        if !envKeys.isEmpty { args += ["--env-keys", envKeys.sorted().joined(separator: ",")] }
        return args + ["--", command] + arguments
    }

    // MARK: - Claude

    /// Claude's user-scope servers with the local scope for `projectPath` on top (both from
    /// ~/.claude.json), each stdio one rewritten to run through `ht`. Passed with --mcp-config they
    /// replace the same-named originals; http/sse, disabled and eager servers are left out, so
    /// Claude's own config still decides them.
    static func claudeServers(config: [String: Any], projectPath: String, ht: String, eager: Set<String>) -> [String: Any] {
        let project = (config["projects"] as? [String: Any])?[projectPath] as? [String: Any]
        var servers = config["mcpServers"] as? [String: Any] ?? [:]
        servers.merge(project?["mcpServers"] as? [String: Any] ?? [:]) { _, local in local }
        let skipped = Set(project?["disabledMcpServers"] as? [String] ?? []).union(eager).union(reservedNames)
        var wrapped: [String: Any] = [:]
        for (name, value) in servers where !skipped.contains(name) {
            guard var server = value as? [String: Any], (server["type"] as? String ?? "stdio") == "stdio",
                  let command = server["command"] as? String else { continue }
            let env = server["env"] as? [String: String] ?? [:]
            server["command"] = ht
            server["args"] = proxyArguments(name: name, command: command, arguments: server["args"] as? [String] ?? [],
                                            envKeys: Array(env.keys))
            wrapped[name] = server
        }
        return wrapped
    }

    // MARK: - Codex

    /// `-c` overrides that run each stdio server in Codex's config.toml through `ht`; its env, cwd
    /// and timeouts stay as configured. Servers with a url, disabled ones, and names Codex can't
    /// take as a dotted key are left alone.
    static func codexOverrides(configTOML: String, ht: String, eager: Set<String>) -> [String] {
        let servers = codexServers(configTOML)
        var overrides: [String] = []
        for name in servers.keys.sorted() where !eager.contains(name) && !reservedNames.contains(name) {
            let server = servers[name]!
            guard let command = server["command"] as? String, server["url"] == nil, server["enabled"] as? Bool != false,
                  name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else { continue }
            let env = server["env"] as? [String: Any] ?? [:]
            let args = proxyArguments(name: name, command: command, arguments: server["args"] as? [String] ?? [],
                                      envKeys: Array(env.keys))
            overrides += ["-c", "mcp_servers.\(name).command=\(tomlString(ht))",
                          "-c", "mcp_servers.\(name).args=[\(args.map(tomlString).joined(separator: ","))]"]
        }
        return overrides
    }

    /// `[mcp_servers.<name>]` tables (and their `.env` subtables) from a TOML document.
    static func codexServers(_ toml: String) -> [String: [String: Any]] {
        var scanner = TOMLScanner(Array(toml))
        var servers: [String: [String: Any]] = [:]
        var table: [String]? = nil
        while scanner.skipBlank() {
            if scanner.peek == "[" {
                scanner.advance()
                let arrayTable = scanner.peek == "["
                if arrayTable { scanner.advance() }
                let path = scanner.key()
                table = arrayTable ? nil : path
                scanner.skipLine()
                continue
            }
            let key = scanner.key()
            guard scanner.peek == "=" else { scanner.skipLine(); continue }
            scanner.advance()
            let value = scanner.value()
            scanner.skipLine()
            guard let table, let value, table.first == "mcp_servers", key.count == 1 else { continue }
            if table.count == 2 {
                servers[table[1], default: [:]][key[0]] = value
            } else if table.count == 3, table[2] == "env" {
                var env = servers[table[1], default: [:]]["env"] as? [String: Any] ?? [:]
                env[key[0]] = value
                servers[table[1], default: [:]]["env"] = env
            }
        }
        return servers
    }

    static func tomlString(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7f { out += String(format: "\\u%04X", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }
}

/// Enough TOML for MCP server tables: strings, arrays, inline tables, booleans; anything else
/// is kept as its raw text.
private struct TOMLScanner {
    let chars: [Character]
    var index = 0

    init(_ chars: [Character]) { self.chars = chars }

    var peek: Character? { index < chars.count ? chars[index] : nil }
    mutating func advance() { index += 1 }

    mutating func skipSpaces() {
        while let c = peek, c == " " || c == "\t" { advance() }
    }

    /// Skips whitespace, newlines and comments; false at the end.
    mutating func skipBlank() -> Bool {
        while let c = peek {
            if c == "#" { skipLine() } else if c.isWhitespace { advance() } else { return true }
        }
        return false
    }

    mutating func skipLine() {
        while let c = peek, c != "\n" { advance() }
    }

    /// A dotted key: bare or quoted segments.
    mutating func key() -> [String] {
        var parts: [String] = []
        while true {
            skipSpaces()
            if peek == "\"" || peek == "'" {
                parts.append(string() ?? "")
            } else {
                var bare = ""
                while let c = peek, c.isLetter || c.isNumber || c == "_" || c == "-" { bare.append(c); advance() }
                parts.append(bare)
            }
            skipSpaces()
            guard peek == "." else { return parts }
            advance()
        }
    }

    mutating func value() -> Any? {
        skipSpaces()
        switch peek {
        case nil: return nil
        case "\"", "'": return string()
        case "[":
            advance()
            var items: [Any] = []
            while skipBlank(), peek != "]" {
                if peek == "," { advance(); continue }
                let before = index
                guard let item = value() else { return items }
                // A stray `}` (or similar) parses to nothing and consumes nothing: skip it so the loop ends.
                if index == before { advance(); continue }
                items.append(item)
            }
            advance()
            return items
        case "{":
            advance()
            var table: [String: Any] = [:]
            while true {
                skipSpaces()
                guard let c = peek, c != "}", c != "\n" else { advance(); return table }
                if c == "," { advance(); continue }
                let key = self.key()
                guard peek == "=" else { return table }
                advance()
                if let value = value(), let last = key.last { table[last] = value }
            }
        default:
            var raw = ""
            while let c = peek, !",]}#\n".contains(c) { raw.append(c); advance() }
            raw = raw.trimmingCharacters(in: .whitespaces)
            if raw == "true" || raw == "false" { return raw == "true" }
            return raw
        }
    }

    /// A basic ("…", with escapes) or literal ('…') string, single- or multi-line.
    mutating func string() -> String? {
        guard let quote = peek else { return nil }
        let multi = index + 2 < chars.count && chars[index + 1] == quote && chars[index + 2] == quote
        index += multi ? 3 : 1
        if multi && peek == "\n" { advance() }
        var out = ""
        while let c = peek {
            if c == quote, !multi || (index + 2 < chars.count && chars[index + 1] == quote && chars[index + 2] == quote) {
                index += multi ? 3 : 1
                return out
            }
            advance()
            guard quote == "\"", c == "\\", let e = peek else { out.append(c); continue }
            advance()
            switch e {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "r": out.append("\r")
            case "u", "U":
                let length = e == "u" ? 4 : 8
                let hex = String(chars[index..<min(index + length, chars.count)])
                index += length
                if let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) { out.unicodeScalars.append(scalar) }
            default: out.append(e)
            }
        }
        return out
    }
}
