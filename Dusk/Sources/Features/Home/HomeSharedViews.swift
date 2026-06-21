import SwiftUI

struct HomeItemContextMenu: View {
    let item: PlexItem
    let detailsLabel: String
    let onMarkWatched: () -> Void
    let onMarkUnwatched: () -> Void
    let onSelectRoute: (AppNavigationRoute) -> Void

    var body: some View {
        if item.canMarkWatchedFromContextMenu {
            Button("Mark Watched", systemImage: "eye", action: onMarkWatched)
        }

        if item.canMarkUnwatchedFromContextMenu {
            Button("Mark Unwatched", systemImage: "eye.slash", action: onMarkUnwatched)
        }

        Button(detailsLabel, systemImage: "info.circle") {
            onSelectRoute(AppNavigationRoute.destination(for: item))
        }

        if let seasonRoute = item.contextMenuSeasonRoute {
            Button("Go to Season", systemImage: "rectangle.stack") {
                onSelectRoute(seasonRoute)
            }
        }

        if let showRoute = item.contextMenuShowRoute {
            Button("Go to Show", systemImage: "tv.fill") {
                onSelectRoute(showRoute)
            }
        }
    }
}

struct HomeHeroActionButtonLabel: View {
    let title: String
    let systemImage: String
    var fillsWidth: Bool = false

    #if os(tvOS)
    private let minimumButtonWidth: CGFloat = 340
    #endif

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(heroButtonFont)

            Text(title)
                .font(heroButtonFont)
                .lineLimit(1)
        }
        .frame(minHeight: heroButtonMinHeight)
        #if os(tvOS)
        .frame(minWidth: minimumButtonWidth)
        .contentShape(Capsule())
        #else
        .frame(maxWidth: fillsWidth ? .infinity : nil)
        .contentShape(Capsule())
        #endif
        .foregroundStyle(labelColor)
    }

    // iOS draws the home hero button as prominent, `Color.primary`-tinted glass,
    // so its label uses the inverse color for contrast. tvOS keeps translucent
    // glass where the standard `primary` label already reads correctly.
    private var labelColor: Color {
        #if os(tvOS)
        .primary
        #else
        .duskPrimaryActionLabel
        #endif
    }

    private var heroButtonFont: Font {
        #if os(tvOS)
        .subheadline.weight(.semibold)
        #else
        .headline.weight(.semibold)
        #endif
    }

    private var heroButtonMinHeight: CGFloat {
        #if os(tvOS)
        30
        #else
        32
        #endif
    }
}

struct HomeHeroSecondaryActionButtonLabel: View {
    let title: String

    #if os(tvOS)
    private let minimumButtonWidth: CGFloat = 340
    #endif

    var body: some View {
        Text(title)
            .font(heroButtonFont)
            #if os(tvOS)
            .frame(minWidth: minimumButtonWidth)
            .contentShape(Capsule())
            #endif
            .foregroundStyle(Color.primary)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.14), radius: 10, y: 4)
    }

    private var heroButtonFont: Font {
        #if os(tvOS)
        .subheadline.weight(.semibold)
        #else
        .headline.weight(.semibold)
        #endif
    }

    private var horizontalPadding: CGFloat {
        #if os(tvOS)
        18
        #else
        20
        #endif
    }

    private var verticalPadding: CGFloat {
        #if os(tvOS)
        12
        #else
        14
        #endif
    }
}

struct HomeHeroPagerPill: View {
    let isActive: Bool
    let progress: Double

    var body: some View {
        let pillWidth: CGFloat = isActive ? 28 : 10
        let pillHeight: CGFloat = 10
        let fillInset: CGFloat = 1
        let clampedProgress = min(max(progress, 0), 1)

        ZStack(alignment: .leading) {
            Capsule()
                .fill(isActive ? Color.primary.opacity(0.24) : Color.primary.opacity(0.28))

            if isActive {
                Capsule()
                    .fill(Color.primary)
                    .frame(
                        width: max((pillWidth - (fillInset * 2)) * clampedProgress, 0),
                        height: pillHeight - (fillInset * 2)
                    )
                    .padding(fillInset)
                    .clipShape(Capsule())
            }
        }
        .frame(width: pillWidth, height: pillHeight)
        .clipShape(Capsule())
        .overlay {
            if isActive {
                Capsule()
                    .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
            }
        }
    }
}

extension View {
    @ViewBuilder
    func homeHeroNativeButtonStyle() -> some View {
        #if os(tvOS)
        self
            .buttonStyle(.glass)
            .controlSize(.regular)
            .buttonBorderShape(.capsule)
            .tint(Color.primary)
        #elseif os(iOS)
        // Prominent, `Color.primary`-tinted glass so the hero CTA contrasts the
        // artwork behind it (dark in Light mode, light in Dark mode). `.regular`
        // height keeps it a short, wide pill instead of an oversized capsule.
        if #available(iOS 26.0, *) {
            self
                .buttonStyle(.glassProminent)
                .controlSize(.regular)
                .buttonBorderShape(.capsule)
                .tint(Color.primary)
        } else {
            self
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .buttonBorderShape(.capsule)
                .tint(Color.primary)
        }
        #else
        self
        #endif
    }
}
