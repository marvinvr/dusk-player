import Foundation

/// The iOS shell can offer local files without turning a partial server outage
/// into an account-wide failure. Keep this decision independent of navigation.
enum OfflineFallback {
    static func showsDownloads(
        downloadsSupported: Bool,
        sessionReady: Bool,
        networkAvailable: Bool,
        awaitingHomeValidation: Bool = false,
        availability: ServerAvailability,
        hasCompletedPass: Bool,
        connectionFailed: Bool
    ) -> Bool {
        guard downloadsSupported, sessionReady else { return false }
        if !networkAvailable || awaitingHomeValidation { return true }
        if availability == .allDisabled { return false }
        if availability.isReady { return false }
        if case .unreachable = availability { return true }
        return hasCompletedPass && connectionFailed
    }

    /// Only resume an identity that was allowed to sign in automatically.
    /// A saved Home member without its remembered token is not an offline PIN
    /// bypass, and must never fall back to the owner's downloads.
    static func canRestoreProfile(
        automaticSignIn: Bool,
        primaryProfileID: String?,
        homeProfileID: String?,
        hasRememberedToken: Bool
    ) -> Bool {
        guard automaticSignIn else { return false }
        if let homeProfileID {
            return hasRememberedToken || homeProfileID == primaryProfileID
        }
        return primaryProfileID != nil
    }

    static func permitsCachedSession(after error: Error) -> Bool {
        guard let error = error as? PlexServiceError else { return false }
        switch error {
        case .networkError: return true
        case .httpError(let status): return (500...599).contains(status)
        default: return false
        }
    }
}
