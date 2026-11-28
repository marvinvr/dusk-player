import Foundation
import OSLog

/// The Plex PIN sign-in, for `SignInPlexFlowView` and the Mac and tvOS sign-in
/// screens (`PlexSignInFlow`).
extension MediaService {
    /// The Plex sign-in flow, for its own screens.
    var plexSignInFlow: PlexSignInFlow { PlexSignInFlow(account: plexAccount) }

    func generatePin(strong: Bool = false) async throws -> PlexPin {
        try await plexSignInFlow.generatePin(strong: strong)
    }

    func checkPin(_ pinId: Int) async throws -> String? {
        try await plexSignInFlow.checkPin(pinId)
    }

    func authURL(for pin: PlexPin) -> URL? {
        plexSignInFlow.authURL(for: pin)
    }
}
