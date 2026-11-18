import Foundation
import XCTest
import os
@testable import OpenUsage

@MainActor
final class LocalLoginTests: XCTestCase {
    private let codexHome = LocalLogin.codexHome(path: "/tmp/codex-home")

    func testCodexLoginReadsTheAccessTokenButNeverTheRefreshToken() throws {
        let data = Self.codexAuth(accessToken: Self.jwt(["https://api.openai.com/auth": ["chatgpt_account_id": "acct-1"]]))

        let tokens = try LocalLoginVault.tokens(from: data, for: codexHome)

        XCTAssertNil(tokens.refreshToken, "a refresh token here would let OpenUsage rotate the CLI's login")
        XCTAssertEqual(tokens.extras["chatgpt_account_id"], "acct-1")
        XCTAssertEqual(tokens.extras[OAuthTokens.identityKey], "acct-1/me@example.com")
        XCTAssertEqual(LocalLoginVault.label(from: data, for: codexHome), "me@example.com")
    }

    func testClaudeCodeLoginReadsTheAccessTokenButNeverTheRefreshToken() throws {
        let data = Data(#"{"claudeAiOauth":{"accessToken":"claude-access","refreshToken":"claude-refresh","accountUuid":"acct","organizationUuid":"org"}}"#.utf8)

        let tokens = try LocalLoginVault.tokens(from: data, for: .claudeCode)

        XCTAssertEqual(tokens.accessToken, "claude-access")
        XCTAssertNil(tokens.refreshToken)
        XCTAssertEqual(tokens.extras[OAuthTokens.identityKey], "acct/org", "the identity a browser sign-in of the same login gets")
    }

    /// Each refresh follows the token the CLI last saved, and a refused one asks for the CLI rather than
    /// renewing it here.
    func testEachRefreshReadsTheCurrentLoginAndARefusedOneIsNeverRenewed() async throws {
        let saved = OSAllocatedUnfairLock(initialState: "first-token")
        let vault = LocalLoginVault(login: codexHome) { _ in Self.codexAuth(accessToken: saved.withLock { $0 }) }
        let http = RoutingHTTPClient { _ in .json("{}", status: 401) }
        let runtime = AccountProviderRuntime(
            account: Account(kind: .codex, label: "Me", localLogin: codexHome), vault: vault, http: http
        )

        guard case .failure(let failure) = await runtime.refresh() else { return XCTFail("a 401 must fail the refresh") }
        XCTAssertEqual(failure.message, codexHome.expiredMessage)
        XCTAssertFalse(http.requests.contains { $0.url.host() == CodexLogin.tokenURL.host() }, "nothing may renew the CLI's login")

        saved.withLock { $0 = "second-token" }
        _ = await runtime.refresh()
        XCTAssertEqual(http.requests.last?.headers["Authorization"], "Bearer second-token")
    }

    func testAddingACodexHomeSavesNothingInTheKeychainAndRefusesTheSameHomeTwice() async throws {
        let vault = InMemoryCredentialVault()
        let store = AccountStore(defaults: isolatedDefaults(), vault: vault)
        let auth = Self.codexAuth(accessToken: "token")
        func add() -> AddAccountFlow {
            let flow = AddAccountFlow(store: store, readLocalLogin: { _ in auth })
            flow.chooseLocalLogin(.codex)
            flow.codexHome = "~/.codex-t3/personal"
            flow.addLocalLogin()
            return flow
        }

        let first = add()
        try await waitUntil { first.isFinished }
        let account = try XCTUnwrap(store.accounts.first)
        XCTAssertEqual(account.label, "me@example.com")
        XCTAssertEqual(account.localLogin, .codexHome(path: NSString(string: "~/.codex-t3/personal").expandingTildeInPath))
        XCTAssertNil(try vault.load(account.id))

        let second = add()
        try await waitUntil { second.errorMessage != nil }
        XCTAssertEqual(second.errorMessage, "This login is already added as me@example.com.")
        XCTAssertEqual(store.accounts.count, 1)
    }

    nonisolated private static func codexAuth(accessToken: String) -> Data {
        let auth: [String: Any] = [
            "OPENAI_API_KEY": NSNull(),
            "tokens": ["access_token": accessToken, "refresh_token": "codex-refresh", "id_token": Self.jwt(["email": "me@example.com"])]
        ]
        return try! JSONSerialization.data(withJSONObject: auth)
    }

    nonisolated private static func jwt(_ claims: [String: Any]) -> String {
        let payload = try! JSONSerialization.data(withJSONObject: claims).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "e30.\(payload).sig"
    }
}
