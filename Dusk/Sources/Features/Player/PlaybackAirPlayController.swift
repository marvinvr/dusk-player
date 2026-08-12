import Foundation
import Observation

#if os(iOS)
import AVFoundation
import AVKit
import SwiftUI
import UIKit
#endif

/// Observes the system media route selected for Dusk's long-form video audio
/// session. The coordinator uses this signal to replace VLC-only/direct-play
/// sources with an AVPlayer-compatible Plex HLS stream before handing video to
/// an AirPlay receiver.
@MainActor @Observable
final class PlaybackAirPlayController {
    private(set) var isAirPlayRouteSelected = false
    private(set) var routeDisplayName: String?
    @ObservationIgnored var routeSelectionDidChange: (@MainActor (Bool) -> Void)?

    #if os(iOS)
    @ObservationIgnored nonisolated(unsafe) private var routeChangeObserver: NSObjectProtocol?

    init() {
        refreshRoute(notify: false)
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshRoute(notify: true)
            }
        }
    }

    deinit {
        if let routeChangeObserver {
            NotificationCenter.default.removeObserver(routeChangeObserver)
        }
    }

    func refreshRoute(notify: Bool = true) {
        let airPlayOutput = AVAudioSession.sharedInstance().currentRoute.outputs.first {
            $0.portType == .airPlay
        }
        let selected = airPlayOutput != nil
        let selectionChanged = selected != isAirPlayRouteSelected

        isAirPlayRouteSelected = selected
        routeDisplayName = airPlayOutput?.portName

        if notify, selectionChanged {
            routeSelectionDidChange?(selected)
        }
    }
    #else
    init() {}

    func refreshRoute(notify: Bool = true) {}
    #endif
}

#if os(iOS)
/// SwiftUI wrapper around Apple's system-owned route picker. The system keeps
/// discovery, authorization, route naming, and connection UI authoritative;
/// Dusk only asks it to prioritize video-capable receivers.
struct PlayerAirPlayRoutePicker: UIViewRepresentable {
    let isActive: Bool

    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = true
        picker.tintColor = .white
        picker.activeTintColor = UIColor(Color.duskAccent)
        return picker
    }

    func updateUIView(_ picker: AVRoutePickerView, context: Context) {
        picker.tintColor = .white
        picker.activeTintColor = UIColor(Color.duskAccent)
        picker.accessibilityLabel = isActive ? "Change AirPlay Device" : "AirPlay"
    }
}
#endif
