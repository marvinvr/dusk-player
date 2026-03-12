import SwiftUI

struct MovieDetailView: View {
    @Environment(PlexService.self) private var plexService
    @Environment(PlaybackCoordinator.self) private var playback
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
                ProgressView()
                    .tint(Color.duskAccent)
            } else if let error = viewModel.error, viewModel.details == nil {
                errorView(error)
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
                    heroSection(details, topInset: geometry.safeAreaInsets.top, containerWidth: geometry.size.width)
                    metadataSection(details)
                        .padding(.horizontal, 20)
                        .padding(.top, 24)
                    actionButtons(details)
                        .padding(.horizontal, 20)
                        .padding(.top, 24)
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
            .ignoresSafeArea(edges: .top)
            .scrollIndicators(.hidden)
        }
    }

    // MARK: - Hero

    @ViewBuilder
    private func heroSection(_ details: PlexMediaDetails, topInset: CGFloat, containerWidth: CGFloat) -> some View {
        let heroHeight = 320 + topInset
        let backdropWidth = Int(containerWidth.rounded(.up))
        let backdropHeight = Int(heroHeight.rounded(.up))

        ZStack(alignment: .bottomLeading) {
            // Backdrop
            if let url = viewModel.backdropURL(width: backdropWidth, height: backdropHeight) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    default:
                        Color.duskSurface
                    }
                }
                .frame(height: heroHeight)
                .frame(maxWidth: .infinity)
                .clipped()
            } else {
                Color.duskSurface
                    .frame(height: heroHeight)
                    .frame(maxWidth: .infinity)
            }

            // Gradient fade to background
            LinearGradient(
                colors: [.clear, Color.duskBackground.opacity(0.6), Color.duskBackground],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: heroHeight)
            .frame(maxWidth: .infinity)

            // Poster + Title overlay
            HStack(alignment: .bottom, spacing: 16) {
                if let posterURL = viewModel.posterURL(width: 100, height: 150) {
                    AsyncImage(url: posterURL) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(2/3, contentMode: .fit)
                        default:
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color.duskSurface)
                                .aspectRatio(2/3, contentMode: .fit)
                        }
                    }
                    .frame(width: 100)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(details.title)
                        .font(.title2.bold())
                        .foregroundStyle(Color.duskTextPrimary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .layoutPriority(1)

                    metadataTagline(details)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .frame(height: heroHeight)
        .frame(maxWidth: .infinity)
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
                .font(.subheadline)
                .foregroundStyle(Color.duskTextSecondary)
        }
    }

    // MARK: - Metadata

    @ViewBuilder
    private func metadataSection(_ details: PlexMediaDetails) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let genres = viewModel.genreText {
                Text(genres)
                    .font(.subheadline)
                    .foregroundStyle(Color.duskTextSecondary)
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
                    .foregroundStyle(Color.duskTextSecondary)
            }

            if let studio = details.studio {
                Text(studio)
                    .font(.caption)
                    .foregroundStyle(Color.duskTextSecondary)
            }
        }
    }

    @ViewBuilder
    private func ratingBadge(icon: String, value: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(color)
            Text(value)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(Color.duskTextPrimary)
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private func actionButtons(_ details: PlexMediaDetails) -> some View {
        VStack(spacing: 12) {
            // Play / Resume button
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
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.duskAccent)
                .foregroundStyle(.white)
                .clipShape(Capsule())
            }
            .duskSuppressTVOSButtonChrome()

            // Mark Watched / Unwatched
            Button {
                Task { await viewModel.toggleWatched() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: viewModel.isWatched ? "eye.slash" : "eye")
                    Text(viewModel.isWatched ? "Mark Unwatched" : "Mark Watched")
                }
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
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

    // MARK: - Error

    @ViewBuilder
    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(Color.duskTextSecondary)
            Text(message)
                .foregroundStyle(Color.duskTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button("Retry") {
                Task { await viewModel.loadDetails() }
            }
            .foregroundStyle(Color.duskAccent)
            .duskSuppressTVOSButtonChrome()
        }
    }
}
