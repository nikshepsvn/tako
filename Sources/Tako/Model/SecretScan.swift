import Foundation

/// Conservative detection of tokens and keys in text that is about to leave the user's hands:
/// Sumi's notes file (readable by the whole Mac) and Tako Link messages to a friend. It only
/// needs to catch the shapes credentials actually take; a false alarm costs a rewrite, a miss
/// costs a leaked key.
enum SecretScan {
    private static let patterns: [(what: String, pattern: String)] = [
        ("an API key", #"\b(sk|pk|rk)[-_][A-Za-z0-9_-]{16,}"#),
        ("a GitHub token", #"\b(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})"#),
        ("an AWS access key", #"\bAKIA[0-9A-Z]{16}\b"#),
        ("a Slack token", #"\bxox[abposr]-[A-Za-z0-9-]{10,}"#),
        ("a Google API key", #"\bAIza[0-9A-Za-z_-]{35}"#),
        ("a private key", #"-----BEGIN [A-Z ]*PRIVATE KEY"#),
        ("a JSON web token", #"\beyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#),
        ("a bearer token", #"\bbearer\s+[A-Za-z0-9._~+/=-]{20,}"#),
        ("a password in a URL", #"\b[a-z][a-z0-9+.-]*://[^\s/:@]+:[^\s/@]{3,}@"#),
        ("a password or token", #"\b(password|passwd|secret|api[_-]?key|token)\s*[:=]\s*\S{6,}"#),
    ]

    /// What kind of secret `text` seems to contain, or nil.
    static func reason(_ text: String) -> String? {
        patterns.first { text.range(of: $0.pattern, options: [.regularExpression, .caseInsensitive]) != nil }?.what
    }
}
