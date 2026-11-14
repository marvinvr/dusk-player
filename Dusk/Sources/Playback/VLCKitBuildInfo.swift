#if canImport(MobileVLCKit)
import MobileVLCKit
#elseif canImport(TVVLCKit)
import TVVLCKit
#elseif canImport(VLCKit)
import VLCKit
#endif
import Foundation
import Darwin

/// What the embedded VLCKit build can do beyond VideoLAN's stock binaries.
///
/// Dusk ships its own MobileVLCKit/TVVLCKit 3.x build
/// (`ci_scripts/build_vlckit.sh`) with ffmpeg's TrueHD/MLP decoders
/// re-enabled. The build script stamps every framework slice's Info.plist, so
/// the app reads the capability from the binary it actually loaded: a stock
/// VideoLAN framework (a stale local `Frameworks/`) keeps the old routing,
/// where TrueHD is undecodable and goes through Plex.
enum VLCKitBuildInfo {
    /// Dusk build label (e.g. `3.7.3-dusk1`); nil for a stock VideoLAN build.
    static let duskBuild: String? = frameworkInfo["DuskVLCKitBuild"] as? String

    /// Whether libvlc decodes Dolby TrueHD/MLP (to PCM, up to 7.1; for TrueHD
    /// Atmos that is the 7.1 bed).
    static let decodesTrueHD: Bool = frameworkInfo["DuskVLCKitTrueHD"] as? Bool ?? false

    /// Query the loaded binary, including older Dusk builds without an AV1
    /// capability stamp. Stock/stale builds must not promise a missing decoder.
    static let decodesAV1: Bool = {
        #if canImport(MobileVLCKit) || canImport(TVVLCKit) || canImport(VLCKit)
        guard let executable = Bundle(for: VLCMediaPlayer.self).executablePath,
              let handle = dlopen(executable, RTLD_LAZY | RTLD_NOLOAD) else { return false }
        defer { dlclose(handle) }
        return dlsym(handle, "dav1d_open") != nil && dlsym(handle, "dav1d_get_picture") != nil
        #else
        return false
        #endif
    }()

    private static var frameworkInfo: [String: Any] {
        #if canImport(MobileVLCKit) || canImport(TVVLCKit) || canImport(VLCKit)
        Bundle(for: VLCMediaPlayer.self).infoDictionary ?? [:]
        #else
        [:]
        #endif
    }
}
