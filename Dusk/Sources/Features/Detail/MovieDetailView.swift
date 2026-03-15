import SwiftUI

struct MovieDetailView: View {
    @Environment(PlexService.self) private var plexService
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var viewModel: MovieDetailViewModel

    init(ratingKey: String, plexService: PlexService) {
        _viewModel = State(initialValue: MovieDetailViewModel(
            ratingKey: ratingKey,
            plexService: plexService
        ))
    }

    var body: some View {
        ZStack {
            Color.duskBackground.ignoresSafeArea()

            if viewModel.isLoading && viewModel.details == nil {
                FeatureLoadingView()
            } else if let error = viewModel.error, viewModel.details == nil {
                FeatureErrorView(message: error) {
                    Task { await viewModel.loadDetails() }
                }
            } else if let details = viewModel.details {
                contentView(details)
            }
        }
        .duskNavigationBarTitleDisplayModeInline()
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task {
            await viewModel.loadDetails()
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func contentView(_ details: PlexMediaDetails) -> some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    heroSection(details, topInset: geometry.safeAreaInsets.top, containerWidth: geometry.size.width, containerHeight: geometry.size.height)
                    if let summary = details.summary, !summary.isEmpty {
                        summarySection(summary)
                            .padding(.horizontal, 20)
                            .padding(.top, 24)
                    }
                    if let roles = details.roles, !roles.isEmpty {
                        castSection(roles)
                            .padding(.top, 24)
                    }
                    mediaInfoSection()
                        .padding(.horizontal, 20)
                        .padding(.top, 24)
                        .padding(.bottom, 40)
                }
                .padding(.top, -geometry.safeAreaInsets.top)
                .frame(width: geometry.size.width, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .scrollIndicators(.hidden)
        }
    }

    // MARK: - Hero

    @ViewBuilder
    private func heroSection(_ details: PlexMediaDetails, topInset: CGFloat, containerWidth: CGFloat, containerHeight: CGFloat) -> some View {
        let heroBase = min(max(containerHeight * 0.72, 520), 760)
        let heroHeight = heroBase + topInset
        let posterWidth = sizeClass == .regular ? 180 : 120
        let posterHeight = Int((Double(posterWidth) * 1.5).rounded())
        DetailHeroSection(
            backdropURL: viewModel.backdropURL(width: Int(containerWidth.rounded(.up)), height: Int(heroHeight.rounded(.up))),
            posterURL: viewModel.posterURL(width: posterWidth, height: posterHeight),
            title: details.title,
            topInset: topInset,
            containerWidth: containerWidth,
            heroBaseHeight: heroBase,
            posterWidth: CGFloat(posterWidth)
        ) {
            VStack(alignment: .leading, spacing: 6) {
                metadataTagline(details)
                heroMetadata(details)
            }
        } actions: {
            actionButtons(details)
        }
    }

    @ViewBuilder
    private func metadataTagline(_ details: PlexMediaDetails) -> some View {
        let parts = [
            details.year.map(String.init),
            details.contentRating,
            viewModel.formattedDuration,
        ].compactMap { $0 }

        if !parts.isEmpty {
            Text(parts.joined(separator: " · "))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.white.opacity(0.76))
        }
    }

    @ViewBuilder
    private func heroMetadata(_ details: PlexMediaDetails) -> some View {
        if let genres = viewModel.genreText {
            Text(genres)
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.76))
        }

        if let rating = details.rating {
            HStack(spacing: 12) {
                ratingBadge(
                    icon: "star.fill",
                    value: String(format: "%.1f", rating),
                    color: .yellow
                )
                if let audience = details.audienceRating {
                    ratingBadge(
                        icon: "person.fill",
                        value: String(format: "%.0f%%", audience * 10),
                        color: Color.duskAccent
                    )
                }
            }
        }

        if let director = viewModel.directorText {
            Text("Directed by \(director)")
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.76))
        }

        if let studio = details.studio {
            Text(studio)
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.76))
        }
    }

    private func ratingBadge(icon: String, value: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(color)
            Text(value)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(Color.white)
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private func actionButtons(_ details: PlexMediaDetails) -> some View {
        let layout = sizeClass == .regular
            ? AnyLayout(HStackLayout(spacing: 12))
            : AnyLayout(VStackLayout(spacing: 12))

        layout {
            Button {
                Task { await playback.play(ratingKey: details.ratingKey) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                    if let resume = viewModel.formattedResume {
                        Text("Resume from \(resume)")
                    } else {
                        Text("Play")
                    }
                }
                .font(.headline)
                .frame(maxWidth: usesFullWidthActionButtons ? .infinity : nil)
                .padding(.vertical, 14)
                .padding(.horizontal, usesFullWidthActionButtons ? 0 : 18)
                .background(Color.duskAccent)
                .foregroundStyle(.white)
                .clipShape(Capsule())
            }
            .duskSuppressTVOSButtonChrome()

            Button {
                Task { await viewModel.toggleWatched() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: viewModel.isWatched ? "eye.slash" : "eye")
                    Text(viewModel.isWatched ? "Mark Unwatched" : "Mark Watched")
                }
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: usesFullWidthActionButtons ? .infinity : nil)
                .padding(.vertical, 12)
                .padding(.horizontal, usesFullWidthActionButtons ? 0 : 18)
                .background(Color.duskSurface)
                .foregroundStyle(Color.duskTextPrimary)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(Color.white.opacity(0.05), lineWidth: 1)
                )
            }
            .duskSuppressTVOSButtonChrome()
        }
    }

    private var usesFullWidthActionButtons: Bool {
        sizeClass == .compact
    }

    // MARK: - Summary

    @ViewBuilder
    private func summarySection(_ summary: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Synopsis")
                .font(.headline)
                .foregroundStyle(Color.duskTextPrimary)

            Text(summary)
                .font(.body)
                .foregroundStyle(Color.duskTextSecondary)
                .lineSpacing(4)
        }
    }

    // MARK: - Cast

    @ViewBuilder
    private func castSection(_ roles: [PlexRole]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cast")
                .font(.headline)
                .foregroundStyle(Color.duskTextPrimary)
                .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(Array(roles.prefix(20).enumerated()), id: \.offset) { _, role in
                        castCard(role)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    @ViewBuilder
    private func castCard(_ role: PlexRole) -> some View {
        ActorCreditCard(person: PlexPersonReference(role: role), plexService: plexService)
    }

    // MARK: - Media Info

    @ViewBuilder
    private func mediaInfoSection() -> some View {
        if let info = viewModel.mediaInfo {
            VStack(alignment: .leading, spacing: 8) {
                Text("Media")
                    .font(.headline)
                    .foregroundStyle(Color.duskTextPrimary)

                Text(info)
                    .font(.subheadline.monospaced())
                    .foregroundStyle(Color.duskTextSecondary)
            }
        }
    }
}
