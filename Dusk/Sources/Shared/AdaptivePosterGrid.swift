import SwiftUI

struct AdaptivePosterGridLayout {
    let columns: [GridItem]
    let posterWidth: CGFloat

    static func make(
        containerWidth: CGFloat,
        horizontalPadding: CGFloat,
        gridSpacing: CGFloat,
        preferredPosterWidth: CGFloat,
        minimumColumnCount: Int = 2
    ) -> Self {
        let availableWidth = max(containerWidth - (horizontalPadding * 2), preferredPosterWidth)
        #if os(macOS)
        // A resizable window: posters stay about the preferred size (never
        // wider than ~15% over it) and the column count follows the width,
        // like the TV app's grid, instead of a narrow window's few columns
        // stretching each poster.
        let maximumPosterWidth = (preferredPosterWidth * 1.15).rounded()
        let rawColumnCount = Int(((availableWidth + gridSpacing) / (maximumPosterWidth + gridSpacing)).rounded(.up))
        #else
        let rawColumnCount = Int((availableWidth + gridSpacing) / (preferredPosterWidth + gridSpacing))
        #endif
        let columnCount = max(rawColumnCount, minimumColumnCount)
        let totalSpacing = CGFloat(columnCount - 1) * gridSpacing
        let posterWidth = floor((availableWidth - totalSpacing) / CGFloat(columnCount))
        let columns = Array(
            repeating: GridItem(.fixed(posterWidth), spacing: gridSpacing, alignment: .top),
            count: columnCount
        )

        return Self(columns: columns, posterWidth: posterWidth)
    }
}
