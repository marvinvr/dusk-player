import Foundation

/// One provider's sign-in screens (docs/jellyfin/04-architecture.md §7.2). The
/// sign-in host (`SignInView`) lists the registry's flows and shows the chosen
/// flow's steps; every flow ends by handing the facade a signed-in
/// `StoredAccount`. Plex is the only flow until J-01, so the host shows it
/// directly, without a picker.
protocol SignInFlow: Sendable {
    var kind: ProviderKind { get }
    /// The provider's product name, for the host's picker row.
    var productName: String { get }
}
