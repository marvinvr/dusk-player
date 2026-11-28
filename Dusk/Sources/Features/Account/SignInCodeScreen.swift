#if os(tvOS)
import SwiftUI
import CoreImage.CIFilterBuiltins

/// The Apple TV code screen every sign-in flow shares
/// (docs/jellyfin/04-architecture.md §7.2): a short code as separate glass
/// tiles, read from the couch and typed on another device, with an optional
/// QR code beside it. Only the title, the instruction line and the actions
/// come from the flow (Plex: plex.tv/link; Jellyfin: Quick Connect).
struct SignInCodeScreen<Actions: View>: View {
    let title: String
    let instructions: Text
    /// nil while the code is being fetched.
    let code: String?
    /// How many tiles to show before the code arrives.
    let codeLength: Int
    /// Shows the QR panel, which encodes `qrPayload` once there is one.
    let showsQRCode: Bool
    let qrPayload: String?
    let status: String
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(alignment: .center, spacing: 96) {
            if showsQRCode {
                qrCodePanel
            }

            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(DuskFont.TV.pageTitle)
                    .foregroundStyle(Color.duskTextPrimary)

                instructions
                    .font(DuskFont.TV.pageSubtitle)
                    .foregroundStyle(Color.duskTextSecondary)
                    .lineSpacing(4)
                    .fixedSize()
                    .padding(.top, 14)

                codeTiles
                    .padding(.top, 44)

                HStack(spacing: 14) {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 28, height: 28)
                    Text(status)
                        .font(DuskFont.TV.caption)
                        .foregroundStyle(Color.duskTextSecondary)
                }
                .padding(.top, 28)

                HStack(spacing: 24) {
                    actions
                }
                .padding(.top, 48)
            }
            .fixedSize()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The QR code on a white card (its quiet zone), so phones read it on the
    /// dark background.
    private var qrCodePanel: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 36, style: .continuous)
                .fill(.white)

            if let qrPayload, let qrImage = SignInQRCode.image(for: qrPayload) {
                Image(decorative: qrImage, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(36)
            } else {
                ProgressView()
                    .tint(.black)
            }
        }
        .frame(width: 480, height: 480)
    }

    /// The code as separate glass tiles, so it can't be mistaken for a word.
    private var codeTiles: some View {
        let characters = code.map { $0.map(String.init) } ?? Array(repeating: " ", count: codeLength)
        return HStack(spacing: 18) {
            ForEach(Array(characters.enumerated()), id: \.offset) { _, character in
                Text(character)
                    .font(.system(size: 76, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.duskTextPrimary)
                    .frame(width: 112, height: 136)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            }
        }
    }
}

/// A full-width action on the code screen, styled like the flows' own.
struct SignInCodeScreenButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(DuskFont.TV.buttonLabel)
                .frame(minWidth: 220)
        }
        .detailHeroNativePrimaryButtonStyle()
    }
}

/// Renders a QR code at one pixel per module. The view scales it up with
/// `.interpolation(.none)`, so the modules stay sharp at any size.
enum SignInQRCode {
    private static let context = CIContext()

    static func image(for string: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        return context.createCGImage(output, from: output.extent)
    }
}
#endif
