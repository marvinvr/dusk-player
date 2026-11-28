import Foundation

/// A signed-in account as this device remembers it (docs/jellyfin/04-architecture.md
/// §7.1). Each provider reads its own records in place from the credentials it
/// already stores (`ProviderFactory.storedAccounts()`); nothing here is
/// persisted, so an install that signed in before accounts existed is read
/// exactly as it was written.
struct StoredAccount: Sendable, Hashable, Identifiable {
    let id: String
    let kind: ProviderKind
    let displayName: String
    /// The Keychain item that holds the account's credential.
    let credentialRef: String
    /// The device id the provider signs requests with for this account, when
    /// it keeps one per account (Jellyfin). nil: the install-wide identifier.
    let deviceID: String?
}
