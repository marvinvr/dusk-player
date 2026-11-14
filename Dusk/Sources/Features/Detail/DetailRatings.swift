import SwiftUI

/// The signed-in user's rating of the title on a detail page, shared by the
/// hero's ratings line and its Rate menu so a new rating shows at once.
@MainActor
@Observable
final class DetailUserRatingModel {
    /// Plex's 0–10 scale.
    private(set) var value: Double?
    private(set) var error: String?

    func sync(_ value: Double?) {
        self.value = value
    }

    /// - Parameter stars: 1–5, or nil to clear.
    func rate(_ stars: Int?, id: PlexItemID, plexService: PlexService) async {
        let previous = value
        value = stars.map { Double($0 * 2) }
        do {
            try await plexService.setUserRating(stars.map { $0 * 2 }, id: id)
        } catch {
            value = previous
            self.error = error.localizedDescription
        }
    }
}

/// The hero's ratings line: the user's own stars (system yellow, STYLE's one
/// star-rating colour), then each source Plex knows as its official logo beside
/// the score in the metadata type. A source without a logo (TVDB) keeps a text
/// label. Absent when there is nothing to show.
///
/// The logos draw exactly as supplied: their owners forbid tinting them or
/// lowering their opacity, and Rotten Tomatoes wants its icon left of the score.
/// `logoSpacing` is IMDb's clear space, two widths of the wordmark's "I".
struct DetailRatingsLine: View {
    let ratings: [PlexRating]
    let userRating: Double?

    #if os(tvOS)
    private let logoHeight: CGFloat = 28
    private let logoSpacing: CGFloat = 12
    private let sourceSpacing: CGFloat = 28
    #elseif os(macOS)
    // Single-line marks at about the 11pt line's height, on its centre line.
    private let logoHeight: CGFloat = 13
    private let logoSpacing: CGFloat = 5
    private let sourceSpacing: CGFloat = 14
    #else
    @ScaledMetric(relativeTo: .subheadline) private var logoHeight: CGFloat = 16
    @ScaledMetric(relativeTo: .subheadline) private var logoSpacing: CGFloat = 7
    @ScaledMetric(relativeTo: .subheadline) private var sourceSpacing: CGFloat = 16
    #endif

    var body: some View {
        if userRating != nil || !ratings.isEmpty {
            HStack(spacing: sourceSpacing) {
                if let userRating {
                    DetailUserStars(rating: userRating)
                }
                ForEach(ratings, id: \.self) { rating in
                    if let display = rating.display {
                        HStack(spacing: logoSpacing) {
                            if let logo = Self.drawnLogo(display.logo) {
                                Image(logo.rawValue)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(height: logoHeight * logo.relativeHeight)
                                    .accessibilityLabel(display.source)
                            } else {
                                Text(display.source)
                                    .font(DuskFont.caption(ios: .caption.weight(.semibold)))
                                    .foregroundStyle(Color.primary.opacity(0.6))
                            }
                            Text(display.value)
                                .font(DuskFont.metadata(ios: .subheadline).monospacedDigit())
                                .foregroundStyle(Color.primary.opacity(0.84))
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
    }

    /// The logo drawn for a source, or nil for its text label. The Mac's
    /// 11pt metadata line is too small for TMDB's stacked two-line mark, so
    /// it reads "TMDB" like the text-only sources there.
    private static func drawnLogo(_ logo: PlexRating.Logo?) -> PlexRating.Logo? {
        #if os(macOS)
        logo == .tmdb ? nil : logo
        #else
        logo
        #endif
    }
}

/// Five small stars for a 0–10 rating, half stars included.
private struct DetailUserStars: View {
    let rating: Double

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { star in
                Image(systemName: symbol(for: star))
                    .font(DuskFont.glyphSmall(ios: .caption2))
                    .foregroundStyle(.yellow)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Your rating: \(rating / 2, specifier: "%g") of 5 stars")
    }

    private func symbol(for star: Int) -> String {
        let points = rating - Double((star - 1) * 2)
        if points >= 2 { return "star.fill" }
        if points >= 1 { return "star.leadinghalf.filled" }
        return "star"
    }
}

/// The hero's Rate action: an icon-only secondary that opens a menu of star
/// ratings (and Clear). The icon fills once the title is rated.
struct DetailRateHeroButton: View {
    @Environment(PlexService.self) private var plexService

    let model: DetailUserRatingModel
    let id: PlexItemID

    var body: some View {
        Menu {
            Section("Your Rating") {
                ForEach((1...5).reversed(), id: \.self) { stars in
                    Button {
                        Task { await model.rate(stars, id: id, plexService: plexService) }
                    } label: {
                        let title = stars == 1 ? "1 Star" : "\(stars) Stars"
                        if currentStars == stars {
                            Label(title, systemImage: "checkmark")
                        } else {
                            Text(title)
                        }
                    }
                }
            }
            if model.value != nil {
                Button("Clear Rating", role: .destructive) {
                    Task { await model.rate(nil, id: id, plexService: plexService) }
                }
            }
        } label: {
            DetailHeroSecondaryIconLabel(systemImage: model.value == nil ? "star" : "star.fill", title: "Rate")
        }
        .detailHeroNativeSecondaryButtonStyle()
        .accessibilityLabel("Rate")
        #if os(macOS)
        // A Menu's label tooltip doesn't reach the pop-up control itself.
        .help("Rate")
        #endif
    }

    /// Whole stars for the checkmark; a half-star rating from another client
    /// checks nothing.
    private var currentStars: Int? {
        guard let value = model.value, value.truncatingRemainder(dividingBy: 2) == 0 else { return nil }
        return Int(value / 2)
    }
}
