import Foundation

/// Plex's sign-in (docs/jellyfin/04-architecture.md §7.2): a plex.tv PIN,
/// approved in the browser (iOS, macOS) or by entering the link code at
/// plex.tv/link (tvOS), polled until it carries the account token. The steps
/// are `SignInPlexFlowView`; the result goes to `MediaService.completeSignIn`.
struct PlexSignInFlow: SignInFlow {
    let account: PlexAccountProvider

    var kind: ProviderKind { .plex }
    var productName: String { "Plex" }

    @MainActor
    func generatePin(strong: Bool = false) async throws -> PlexPin {
        try await account.plexTVRequest(
            method: "POST",
            path: "/api/v2/pins",
            formBody: strong ? ["strong": "true"] : nil
        )
    }

    /// The account token once the PIN was approved, nil while it is pending.
    @MainActor
    func checkPin(_ pinId: Int) async throws -> String? {
        let pin: PlexPin = try await account.plexTVRequest(path: "/api/v2/pins/\(pinId)")
        return pin.authToken
    }

    @MainActor
    func authURL(for pin: PlexPin) -> URL? {
        URL(string: "https://app.plex.tv/auth#?clientID=\(account.client.clientIdentifier)&code=\(pin.code)&context%5Bdevice%5D%5Bproduct%5D=Dusk")
    }

    /// The signed-in account a returned token stands for.
    func storedAccount() -> StoredAccount {
        StoredAccount(
            id: PlexAccountProvider.accountID,
            kind: .plex,
            displayName: account.account.displayName,
            credentialRef: PlexAccountProvider.keychainTokenKey,
            deviceID: nil
        )
    }
}
