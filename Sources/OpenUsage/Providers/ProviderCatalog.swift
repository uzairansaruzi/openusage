import Foundation

@MainActor
enum ProviderCatalog {
    /// One runtime per account, reusing each account's runtime when it still fits. An account mirrored
    /// from a hub gets a runtime whose HTTP client tunnels through that hub, rebuilt when its link changes;
    /// while hubs are off, its client sends nothing. An account that reads a local login reads it
    /// through its own `LocalLoginVault`.
    static func make(
        accounts: [Account],
        vault: any CredentialVault,
        hubKeys: any HubKeyVault = KeychainHubKeyVault(),
        http: any HTTPClient = URLSessionHTTPClient(),
        hubGate: CLIProxyHubGate = CLIProxyHubGate(),
        hubsEnabled: Bool = CLIProxyHub.isEnabled,
        hubLoginMissing: @escaping @Sendable (UUID) async -> Void = { _ in },
        claudeSessions: ClaudeSessions = ClaudeSessions(),
        reusing existing: [AccountProviderRuntime] = []
    ) -> [AccountProviderRuntime] {
        let existingByID = Dictionary(existing.map { ($0.account.id, $0) }, uniquingKeysWith: { first, _ in first })
        return accounts.map { account in
            guard let runtime = existingByID[account.id], runtime.account.hub == account.hub else {
                let client: any HTTPClient = switch account.hub {
                case nil: http
                case let link? where hubsEnabled:
                    HubTunnel(
                        link: link, kind: account.kind, keys: hubKeys,
                        client: CLIProxyHubClient(http: http, gate: hubGate, loginMissing: hubLoginMissing)
                    )
                case _?: HubOff()
                }
                let accountVault: any CredentialVault = account.localLogin.map { LocalLoginVault(login: $0) } ?? vault
                return AccountProviderRuntime(account: account, vault: accountVault, http: client, claudeSessions: claudeSessions)
            }
            runtime.update(account)
            return runtime
        }
    }
}
