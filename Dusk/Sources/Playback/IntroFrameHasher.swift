import CoreGraphics
import CoreVideo
import Foundation
import VideoToolbox
#if canImport(UIKit)
import UIKit
#endif

/// Both engine adapters use this exact sRGB, unpadded resampling path.
/// Geometry and quality checks are independent of the player view's fill mode.
enum IntroFrameHasher {
    static let side = 64
    private static let rgbaComponentCount = 4
    private static let bitsPerColorComponent = 8
    private static let redLuminanceWeight = 0.299
    private static let greenLuminanceWeight = 0.587
    private static let blueLuminanceWeight = 0.114
    private static let qualityCropInsetDivisor = 8
    private static let contrastLowerPercentile = 5
    private static let contrastUpperPercentile = 95
    private static let minimumContrast = 6.0
    private static let minimumGradient = 0.75
    private static let gradientHashSide = 8
    private static let minimumQuality = 0.5
    private static let qualityHeadroom = 0.5
    private static let fullQualityContrast = 96.0
    private static let fullQualityGradient = 10.0

    static func hash(pixelBuffer: CVPixelBuffer) -> IntroFrameSignature? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else { return nil }
        var image: CGImage?
        guard VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &image) == noErr,
              let image else { return nil }
        return hash(cgImage: image)
    }

    #if canImport(UIKit)
    static func hash(image: UIImage) -> IntroFrameSignature? {
        guard let cgImage = image.cgImage else { return nil }
        return hash(cgImage: cgImage)
    }
    #endif

    static func hash(cgImage: CGImage) -> IntroFrameSignature? {
        guard cgImage.width > 0, cgImage.height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var rgba = [UInt8](repeating: 0, count: side * side * rgbaComponentCount)
        let rendered = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress,
                  let context = CGContext(
                    data: base, width: side, height: side,
                    bitsPerComponent: bitsPerColorComponent, bytesPerRow: side * rgbaComponentCount, space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
                  ) else { return false }
            context.interpolationQuality = .high
            // Fill the destination with the entire decoded picture. Artificial
            // letterboxing would make uniform white cards appear high-contrast.
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard rendered else { return nil }
        let luminance = stride(from: 0, to: rgba.count, by: rgbaComponentCount).map { index in
            redLuminanceWeight * Double(rgba[index]) + greenLuminanceWeight * Double(rgba[index + 1])
                + blueLuminanceWeight * Double(rgba[index + 2])
        }
        return hash(luminance: luminance)
    }

    /// Platform-independent arithmetic after canonical image conversion, shared
    /// with the offline media probe. The central crop ignores genuine black bars
    /// for quality measurement, without changing the hash geometry per frame.
    static func hash(luminance: [Double]) -> IntroFrameSignature? {
        guard luminance.count == side * side, luminance.allSatisfy({ $0.isFinite }) else { return nil }
        var center: [Double] = []
        var gradient = 0.0
        let cropInset = side / qualityCropInsetDivisor
        let cropRange = cropInset..<(side - cropInset)
        for y in cropRange {
            for x in cropRange {
                let value = luminance[y * side + x]
                center.append(value)
                gradient += abs(value - luminance[y * side + x - 1])
                gradient += abs(value - luminance[(y - 1) * side + x])
            }
        }
        center.sort()
        let contrast = center[center.count * contrastUpperPercentile / 100]
            - center[center.count * contrastLowerPercentile / 100]
        gradient /= Double(center.count * 2)
        guard contrast >= minimumContrast, gradient >= minimumGradient else { return nil }
        let horizontalSampleWidth = gradientHashSide + 1
        let horizontal = resize(luminance, width: horizontalSampleWidth, height: gradientHashSide)
        let vertical = resize(luminance, width: gradientHashSide, height: gradientHashSide + 1)
        var h: UInt64 = 0
        var v: UInt64 = 0
        for y in 0..<gradientHashSide {
            for x in 0..<gradientHashSide {
                let bit = UInt64(1) << UInt64(y * gradientHashSide + x)
                if horizontal[y * horizontalSampleWidth + x] > horizontal[y * horizontalSampleWidth + x + 1] { h |= bit }
                if vertical[y * gradientHashSide + x] > vertical[(y + 1) * gradientHashSide + x] { v |= bit }
            }
        }
        let quality = minimumQuality + qualityHeadroom * min(1, contrast / fullQualityContrast)
            * min(1, gradient / fullQualityGradient)
        return IntroFrameSignature(hash: IntroFrameHash(horizontal: h, vertical: v), quality: quality)
    }

    /// Area averaging, including fractional boundary pixels, avoids the two
    /// engines producing different gradients through nearest-neighbour sampling.
    private static func resize(_ pixels: [Double], width: Int, height: Int) -> [Double] {
        var output = [Double](repeating: 0, count: width * height)
        let dx = Double(side) / Double(width), dy = Double(side) / Double(height)
        for y in 0..<height {
            for x in 0..<width {
                let left = Double(x) * dx, right = Double(x + 1) * dx
                let top = Double(y) * dy, bottom = Double(y + 1) * dy
                var value = 0.0
                for sy in Int(top)..<min(side, Int(ceil(bottom))) {
                    for sx in Int(left)..<min(side, Int(ceil(right))) {
                        let weight = (min(right, Double(sx + 1)) - max(left, Double(sx)))
                            * (min(bottom, Double(sy + 1)) - max(top, Double(sy)))
                        value += pixels[sy * side + sx] * weight
                    }
                }
                output[y * width + x] = value / (dx * dy)
            }
        }
        return output
    }
}
