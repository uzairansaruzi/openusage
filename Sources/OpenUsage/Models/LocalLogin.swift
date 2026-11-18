import Foundation

/// A sign-in another tool on this Mac already holds, which an account reads instead of keeping its own.
/// OpenUsage reads it fresh on every refresh and never renews or writes it: the tool owns the login, so
/// renewing it here would spend the tool's refresh token and sign the tool out.
enum LocalLogin: Codable, Hashable, Sendable {
    /// Claude Code's sign-in, in its `Claude Code-credentials` Keychain item.
    case claudeCode
    /// A Codex home folder (`~/.codex`, or any `CODEX_HOME`) holding the `auth.json` Codex signs in to.
    case codexHome(path: String)

    static let claudeCodeKeychainService = "Claude Code-credentials"
    static let defaultCodexHome = "~/.codex"

    /// A Codex home from what the user typed: blank means `~/.codex`, and a `~` is expanded, so one
    /// folder always saves as one path.
    static func codexHome(typed: String) -> LocalLogin {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = (text.isEmpty ? defaultCodexHome : text) as NSString
        return .codexHome(path: (path.expandingTildeInPath as NSString).standardizingPath)
    }

    /// Where the login lives, as the account's page shows it.
    var source: String {
        switch self {
        case .claudeCode: "Claude Code’s Keychain Login"
        case .codexHome(let path): (path as NSString).abbreviatingWithTildeInPath
        }
    }

    /// The login the tool holds can't read usage any more: only the tool itself can renew it.
    var expiredMessage: String {
        switch self {
        case .claudeCode: "Claude Code’s sign-in has expired. Run Claude Code once to renew it."
        case .codexHome: "The Codex sign-in in \(source) has expired. Run Codex with that home once to renew it."
        }
    }
}
