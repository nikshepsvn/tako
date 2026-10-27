import AppKit
import CefSwiftUI
import CommonCrypto
import Security
import SQLite3

/// Copies the user's Chrome cookies into the shared browser so sites they're signed in to in
/// Chrome are signed in here too. A different profile folder means a different encryption key,
/// so Chrome's profile can't be opened directly: cookies are decrypted (with the "Chrome Safe
/// Storage" Keychain password, which macOS asks the user to allow) and set over DevTools.
@MainActor
enum BrowserLogins {
    static func importFromChrome(reload page: CefWebViewModel) {
        guard let profile = ChromeProfile.lastUsed() else {
            alert("No Chrome profile found", "Tako looks for Google Chrome's data in ~/Library/Application Support/Google/Chrome.")
            return
        }
        let confirm = NSAlert()
        confirm.messageText = "Import your Chrome logins?"
        confirm.informativeText = """
            Copies the cookies from your Chrome profile "\(profile.name)" into Tako's browser, so sites you're signed in to in Chrome are signed in here.

            Your agents can act on those sites while they use the browser. macOS will ask to let Tako read "Chrome Safe Storage"; choose Allow.
            """
        confirm.addButton(withTitle: "Import")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        guard AgentBrowser.shared.start() else {
            alert("Browser unavailable", AgentBrowser.shared.startError ?? "Chromium didn't start, so there's nowhere to import to.")
            return
        }
        // Chromium opens its DevTools port a moment after starting.
        AgentBrowser.waitUntilReady({ true }) { ready in
            guard ready else {
                alert("Browser unavailable", "Tako's browser didn't come up, so there's nowhere to import to. Try again in a moment.")
                return
            }
            let endpoint = AgentBrowser.endpoint
            Task {
                let outcome = await Task.detached { () -> Result<Int, ImportError> in
                    do {
                        let cookies = try ChromeCookies.read(profile: profile)
                        try await DevTools.setCookies(cookies, endpoint: endpoint)
                        return .success(cookies.count)
                    } catch let error as ImportError {
                        return .failure(error)
                    } catch {
                        return .failure(.devTools(error.localizedDescription))
                    }
                }.value
                switch outcome {
                case .success(let count):
                    alert("Imported \(count) cookies", "Every Tako browser is now signed in where your Chrome is.")
                    page.reload()
                case .failure(let error):
                    alert("Couldn't import Chrome logins", error.description)
                }
            }
        }
    }

    private static func alert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}

enum ImportError: Error, CustomStringConvertible {
    case keychainDenied, database(String), devTools(String)

    var description: String {
        switch self {
        case .keychainDenied: return "macOS didn't allow access to \"Chrome Safe Storage\", which Chrome's cookies are encrypted with."
        case .database(let message): return "Chrome's cookie database couldn't be read: \(message)"
        case .devTools(let message): return "The browser didn't accept the cookies: \(message)"
        }
    }
}

struct ChromeProfile: Sendable {
    let name: String
    let directory: URL

    static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Google/Chrome")

    /// The profile Chrome opened most recently ("Default" unless the user has several).
    static func lastUsed() -> ChromeProfile? {
        let state = (try? Data(contentsOf: root.appendingPathComponent("Local State")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let profiles = state?["profile"] as? [String: Any]
        let folder = profiles?["last_used"] as? String ?? "Default"
        let info = (profiles?["info_cache"] as? [String: Any])?[folder] as? [String: Any]
        let directory = root.appendingPathComponent(folder)
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("Cookies").path) else { return nil }
        return ChromeProfile(name: info?["name"] as? String ?? folder, directory: directory)
    }
}

/// A cookie in the shape DevTools' `Storage.setCookies` takes.
struct BrowserCookie: Sendable, Encodable {
    let name: String
    let value: String
    let domain: String
    let path: String
    let secure: Bool
    let httpOnly: Bool
    let sameSite: String?
    let expires: Double?
}

enum ChromeCookies {
    /// Chrome stores times as microseconds since 1601-01-01.
    private static let windowsEpochOffset: Double = 11_644_473_600

    static func read(profile: ChromeProfile) throws -> [BrowserCookie] {
        let key = try safeStorageKey()
        // Chrome holds the database open; read a copy so we never contend with it.
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("tako-cookies-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        for suffix in ["", "-journal", "-wal"] {
            let source = profile.directory.appendingPathComponent("Cookies" + suffix)
            if FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.copyItem(at: source, to: temp.appendingPathComponent("Cookies" + suffix))
            }
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(temp.appendingPathComponent("Cookies").path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw ImportError.database(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_close(db) }
        // Schema 24+ prefixes each plaintext with a 32-byte hash of the cookie's domain.
        let hashedDomains = (Int(scalar(db, "SELECT value FROM meta WHERE key = 'version'") ?? "") ?? 0) >= 24

        var statement: OpaquePointer?
        let query = "SELECT host_key, name, value, encrypted_value, path, expires_utc, is_secure, is_httponly, samesite, has_expires FROM cookies"
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            throw ImportError.database(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        let now = Date().timeIntervalSince1970
        var cookies: [BrowserCookie] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let encrypted = blob(statement, 3)
            let value = encrypted.isEmpty ? text(statement, 2) : decrypt(encrypted, key: key, hashedDomain: hashedDomains)
            guard let value else { continue }
            let expiresUTC = Double(sqlite3_column_int64(statement, 5))
            let expires = sqlite3_column_int(statement, 9) != 0 && expiresUTC > 0 ? expiresUTC / 1_000_000 - windowsEpochOffset : nil
            if let expires, expires < now { continue }
            let secure = sqlite3_column_int(statement, 6) != 0
            let sameSite: String? = switch sqlite3_column_int(statement, 8) {
            case 0: secure ? "None" : nil   // None without Secure is rejected by Chromium.
            case 1: "Lax"
            case 2: "Strict"
            default: nil
            }
            cookies.append(BrowserCookie(
                name: text(statement, 1) ?? "", value: value, domain: text(statement, 0) ?? "",
                path: text(statement, 4) ?? "/", secure: secure, httpOnly: sqlite3_column_int(statement, 7) != 0,
                sameSite: sameSite, expires: expires))
        }
        return cookies
    }

    // MARK: Crypto

    private static func safeStorageKey() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Chrome Safe Storage",
            kSecAttrAccount as String: "Chrome",
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let password = result as? Data else {
            throw ImportError.keychainDenied
        }
        var key = Data(count: kCCKeySizeAES128)
        let salt = Data("saltysalt".utf8)
        let status = key.withUnsafeMutableBytes { keyBytes in
            password.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                         passwordBytes.baseAddress?.assumingMemoryBound(to: Int8.self), password.count,
                                         saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                                         keyBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), kCCKeySizeAES128)
                }
            }
        }
        guard status == kCCSuccess else { throw ImportError.keychainDenied }
        return key
    }

    /// "v10" + AES-128-CBC with a fixed IV of 16 spaces, as Chrome does on macOS.
    private static func decrypt(_ data: Data, key: Data, hashedDomain: Bool) -> String? {
        guard data.count > 3, data.prefix(3) == Data("v10".utf8) else { return nil }
        let payload = data.dropFirst(3)
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var output = Data(count: payload.count + kCCBlockSizeAES128)
        let capacity = output.count
        var length = 0
        let status = output.withUnsafeMutableBytes { out in
            payload.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                                input.baseAddress, payload.count, out.baseAddress, capacity, &length)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        let plain = output.prefix(length).dropFirst(hashedDomain ? 32 : 0)
        return String(data: plain, encoding: .utf8)
    }

    // MARK: SQLite

    private static func scalar(_ db: OpaquePointer?, _ sql: String) -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? text(statement, 0) : nil
    }

    private static func text(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }

    private static func blob(_ statement: OpaquePointer?, _ column: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }
}

/// Just enough of the DevTools protocol to set cookies on the browser.
enum DevTools {
    static func setCookies(_ cookies: [BrowserCookie], endpoint: String) async throws {
        guard let versionURL = URL(string: endpoint + "/json/version") else { return }
        let (data, _) = try await URLSession.shared.data(from: versionURL)
        guard let info = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let socketURL = (info["webSocketDebuggerUrl"] as? String).flatMap(URL.init(string:)) else {
            throw ImportError.devTools("no DevTools socket")
        }
        let socket = URLSession.shared.webSocketTask(with: socketURL)
        socket.maximumMessageSize = 64 * 1024 * 1024
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }

        struct Command: Encodable {
            struct Params: Encodable { let cookies: [BrowserCookie] }
            let id: Int
            let method = "Storage.setCookies"
            let params: Params
        }
        // Batches keep each message small; a bad cookie only fails its own batch.
        var failures = 0
        for (index, start) in stride(from: 0, to: cookies.count, by: 400).enumerated() {
            let batch = Array(cookies[start..<min(start + 400, cookies.count)])
            let message = try JSONEncoder().encode(Command(id: index + 1, params: .init(cookies: batch)))
            try await socket.send(.string(String(decoding: message, as: UTF8.self)))
            if try await receive(from: socket).contains("\"error\"") { failures += 1 }
        }
        if failures > 0 && failures * 400 >= cookies.count { throw ImportError.devTools("every batch was rejected") }
    }

    /// The next text reply, or an error if the browser says nothing for 10 seconds.
    private static func receive(from socket: URLSessionWebSocketTask) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            let timedOut = ImportError.devTools("the browser didn't answer within 10 seconds")
            group.addTask {
                do {
                    if case .string(let reply) = try await socket.receive() { return reply }
                    return ""
                } catch let error as URLError where error.code == .cancelled {
                    // Our own timeout cancelled the socket: report the timeout, not "cancelled".
                    throw timedOut
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                // Cancelling the socket ends the receive above, so the group can finish.
                socket.cancel(with: .goingAway, reason: nil)
                throw timedOut
            }
            defer { group.cancelAll() }
            return try await group.next() ?? ""
        }
    }
}
