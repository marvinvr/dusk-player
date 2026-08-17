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
///
/// The picker is deliberately glyph-less: both tints are clear so it renders
/// nothing and acts purely as the control surface underneath the symbol
/// `PlayerAirPlayControl` draws. See that view for why.
struct PlayerAirPlayRoutePicker: UIViewRepresentable {
    let isActive: Bool

    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = true
        picker.backgroundColor = .clear
        applyAppearance(to: picker)
        return picker
    }

    func updateUIView(_ picker: AVRoutePickerView, context: Context) {
        applyAppearance(to: picker)
    }

    /// `AVRoutePickerView` has an intrinsic size of its own. Left to report it,
    /// the representable can both grow the stack it sits in and end up with a
    /// touch target that no longer matches the circle Dusk draws around it, so
    /// take the proposal instead.
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: AVRoutePickerView,
        context: Context
    ) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 44, height: 44))
    }

    private func applyAppearance(to picker: AVRoutePickerView) {
        picker.tintColor = .clear
        picker.activeTintColor = .clear
        picker.accessibilityLabel = isActive ? "Change AirPlay Device" : "AirPlay"
    }
}

/// Dusk's AirPlay button face: the app's own symbol with the system route
/// picker invisibly on top, so a tap still opens the system route sheet.
///
/// `AVRoutePickerView` lays its glyph out on its own metrics rather than
/// centering it in whatever size it is given, which leaves the symbol sitting
/// visibly high in a 44pt circle, at a weight that never matches the Close,
/// Picture in Picture, and zoom symbols beside it. Drawing the symbol here is
/// what gets both right, and the system view remains the actual control, so
/// discovery, route naming, and connection UI all stay Apple's.
struct PlayerAirPlayControl: View {
    let isActive: Bool
    var symbolFont: Font = .title3.weight(.semibold)

    var body: some View {
        ZStack {
            Image(systemName: "airplayvideo")
                .font(symbolFont)
                .foregroundStyle(isActive ? Color.duskAccent : .white)
                .accessibilityHidden(true)

            PlayerAirPlayRoutePicker(isActive: isActive)
        }
    }
}
#endif
