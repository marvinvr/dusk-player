import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// Cross-platform names for the few UIKit/AppKit types shared code has to touch
// (decoded images, dynamic colours). iOS/tvOS keep their UIKit types verbatim;
// macOS maps them to AppKit. Anything richer than this belongs behind an
// explicit `#if os(macOS)` branch, not a growing alias layer. See docs/macos.md.

#if canImport(UIKit)
typealias PlatformImage = UIImage
typealias PlatformColor = UIColor
#elseif canImport(AppKit)
typealias PlatformImage = NSImage
typealias PlatformColor = NSColor
#endif

extension Image {
    /// `Image(uiImage:)` / `Image(nsImage:)`.
    init(platformImage: PlatformImage) {
        #if canImport(UIKit)
        self.init(uiImage: platformImage)
        #else
        self.init(nsImage: platformImage)
        #endif
    }
}

#if os(macOS)
extension NSImage {
    /// UIKit-style `cgImage`, the best representation for the image's size.
    var cgImage: CGImage? {
        var rect = CGRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    /// UIKit-style `UIImage(cgImage:)`.
    convenience init(cgImage: CGImage) {
        self.init(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

extension NSColor {
    /// A colour that resolves light/dark from the drawing appearance, like
    /// `UIColor { traits in ... }`.
    static func duskDynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua]) != nil
                ? dark
                : light
        }
    }
}
#endif
