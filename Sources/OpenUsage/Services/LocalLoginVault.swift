import Foundation

/// The credential store of an account that reads a `LocalLogin`: every load reads the tool's login as it
/// is now, so the account follows each renewal the tool makes. Its tokens carry no refresh token, so the
/// runtime never renews them, and nothing is ever written back: the tool stays the only owner.
struct LocalLoginVault: CredentialVault {
    let login: LocalLogin
    /// The login's raw bytes: the Keychain item's JSON or the `auth.json` file. Injected by tests.
    var read: @Sendable (LocalLogin) throws -> Data = LocalLoginVault.readSource

    func load(_ id: UUID) throws -> AccountCredential? {
        .oauth(try Self.tokens(from: read(login), for: login))
    }

    // The tool owns the login: nothing is saved over it, and removing the account leaves the tool signed in.
    func save(_ credential: AccountCredential, for id: UUID) throws {}
    func update(_ credential: AccountCredential, for id: UUID) throws {}
    func delete(_ id: UUID) throws {}

    /// The access token and the account details the usage reads need, from the tool's own JSON. The
    /// refresh token is left out on purpose, so nothing here can renew (and so rotate) the tool's login.
    static func tokens(from data: Data, for login: LocalLogin) throws -> OAuthTokens {
        let json = ProviderParse.jsonObject(data)
        switch login {
        case .claudeCode:
            guard let oauth = json?["claudeAiOauth"] as? [String: Any],
                  let accessToken = oauth["accessToken"] as? String, !accessToken.isEmpty
            else { throw unreadable(login) }
            // The same identity a browser sign-in gets, so both share one session and its request budget.
            let identity = (oauth["accountUuid"] as? String).map {
                ClaudeAccountProfile.identity(accountUUID: $0, organizationUUID: oauth["organizationUuid"] as? String)
            }
            return OAuthTokens(accessToken: accessToken, extras: [OAuthTokens.identityKey: identity ?? "local:claude-code"])
        case .codexHome:
            guard let tokens = json?["tokens"] as? [String: Any] else {
                if json?["OPENAI_API_KEY"] is String {
                    throw ProviderError.unavailable("The Codex login in \(login.source) uses an API key, which has no ChatGPT usage limits.")
                }
                throw unreadable(login)
            }
            guard let accessToken = tokens["access_token"] as? String, !accessToken.isEmpty else { throw unreadable(login) }
            let claims = ProviderParse.jwtPayload(accessToken)?["https://api.openai.com/auth"] as? [String: Any]
            let accountID = tokens["account_id"] as? String ?? claims?["chatgpt_account_id"] as? String
            var extras: [String: String] = [:]
            extras["chatgpt_account_id"] = accountID
            if let accountID, let email = email(in: tokens) { extras[OAuthTokens.identityKey] = "\(accountID)/\(email)" }
            return OAuthTokens(accessToken: accessToken, extras: extras)
        }
    }

    /// What a new account reading the login is named: a Codex login's email, else where the login lives.
    static func label(from data: Data, for login: LocalLogin) -> String {
        switch login {
        case .claudeCode: "Claude Code"
        case .codexHome: (ProviderParse.jsonObject(data)?["tokens"] as? [String: Any]).flatMap(email(in:)) ?? login.source
        }
    }

    private static func email(in codexTokens: [String: Any]) -> String? {
        (codexTokens["id_token"] as? String).flatMap(ProviderParse.jwtPayload)?["email"] as? String
    }

    private static func unreadable(_ login: LocalLogin) -> ProviderError {
        AppLog.error(LogTag.auth("local"), "\(login.source) holds no sign-in OpenUsage can read")
        return .unavailable("OpenUsage can’t read the sign-in in \(login.source). Sign in again with the tool that owns it.")
    }

    /// Reads the login where its tool keeps it. Claude Code's Keychain item is read through
    /// `/usr/bin/security`, which Claude Code saves it with, so macOS doesn't ask for access.
    static func readSource(_ login: LocalLogin) throws -> Data {
        switch login {
        case .claudeCode:
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            process.arguments = ["find-generic-password", "-s", LocalLogin.claudeCodeKeychainService, "-w"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                AppLog.warn(LogTag.auth("local"), "Claude Code's Keychain item isn't readable (security exit \(process.terminationStatus))")
                throw ProviderError.unavailable("No Claude Code sign-in found in your Keychain. Run Claude Code and sign in.")
            }
            return data
        case .codexHome(let path):
            let file = URL(fileURLWithPath: path).appendingPathComponent("auth.json")
            guard FileManager.default.fileExists(atPath: file.path) else {
                throw ProviderError.unavailable("No Codex sign-in in \(login.source). Run `codex login` with that home first.")
            }
            return try Data(contentsOf: file)
        }
    }
}
