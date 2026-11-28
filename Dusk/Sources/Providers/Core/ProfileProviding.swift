import Foundation

/// Profiles on an account: list, switch, current (docs/jellyfin/04-architecture.md
/// §7.3). Empty until P0-16.
protocol ProfileProviding: Sendable {}
