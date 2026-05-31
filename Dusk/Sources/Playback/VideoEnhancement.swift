import CoreVideo
import Foundation
import SwiftUI

enum VideoEnhancementMode: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case enabled
    case disabled

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: "Auto"
        case .enabled: "On"
        case .disabled: "Off"
        }
    }

    var isPotentiallyEnabled: Bool {
        self != .disabled
    }
}

struct VideoEnhancementRequest: Sendable, Equatable {
    static let disabled = VideoEnhancementRequest(mode: .disabled)

    let mode: VideoEnhancementMode
    let sourceWidth: Int?
    let sourceHeight: Int?
    let frameRate: Double?
    let isHDR: Bool

    init(
        mode: VideoEnhancementMode,
        sourceWidth: Int? = nil,
        sourceHeight: Int? = nil,
        frameRate: Double? = nil,
        isHDR: Bool = false
    ) {
        self.mode = mode
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.frameRate = frameRate
        self.isHDR = isHDR
    }

    var isPotentiallyEnabled: Bool {
        mode.isPotentiallyEnabled
    }

    var sourceLabel: String {
        guard let sourceWidth, let sourceHeight else { return "Unknown" }
        return "\(sourceWidth)x\(sourceHeight)"
    }

    var preflightUnavailabilityReason: String? {
        let frameRate = frameRate ?? 0
        if mode == .automatic {
            if isHDR {
                return "Auto skips HDR"
            }
            if frameRate > 50 {
                return "Auto skips >50fps"
            }
        } else if mode == .enabled, frameRate > 70 {
            return "Disabled above 70fps"
        }
        return nil
    }

    static func make(
        mode: VideoEnhancementMode,
        media: PlexMedia,
        part: PlexMediaPart
    ) -> VideoEnhancementRequest {
        let videoStream = part.streams.first { $0.streamType == .video }
        let width = media.width ?? videoStream?.width
        let height = media.height ?? videoStream?.height
        let frameRate = videoStream?.frameRate
        return VideoEnhancementRequest(
            mode: mode,
            sourceWidth: width,
            sourceHeight: height,
            frameRate: frameRate,
            isHDR: videoStream?.isHDRVideo == true
        )
    }
}

struct VideoEnhancementStatus: Sendable, Equatable {
    enum State: Sendable, Equatable {
        case disabled
        case idle
        case active
        case unavailable
    }

    static let disabled = VideoEnhancementStatus(state: .disabled, reason: "Preference is Off")
    static let idle = VideoEnhancementStatus(state: .idle, reason: "Waiting for video frame")

    let state: State
    let reason: String
    let inputSize: CGSize?
    let outputSize: CGSize?

    init(
        state: State,
        reason: String,
        inputSize: CGSize? = nil,
        outputSize: CGSize? = nil
    ) {
        self.state = state
        self.reason = reason
        self.inputSize = inputSize
        self.outputSize = outputSize
    }

    var stateLabel: String {
        switch state {
        case .disabled:
            "Off"
        case .idle:
            "Idle"
        case .active:
            "Active"
        case .unavailable:
            "Unavailable"
        }
    }

    var detailLabel: String {
        var details: [String] = []

        if let inputSize, let outputSize {
            details.append("\(format(inputSize)) -> \(format(outputSize))")
        }

        if !reason.isEmpty {
            details.append(reason)
        }

        return details.joined(separator: " / ")
    }

    var displayLabel: String {
        let detail = detailLabel
        guard !detail.isEmpty else { return stateLabel }
        return "\(stateLabel) - \(detail)"
    }

    private func format(_ size: CGSize) -> String {
        "\(Int(size.width))x\(Int(size.height))"
    }
}

final class VideoEnhancementFrame: @unchecked Sendable {
    enum ChannelLayout: Sendable {
        case bgra
        case rgbaBytesInBGRA
    }

    private let retainedPixelBuffer: Unmanaged<CVPixelBuffer>
    let channelLayout: ChannelLayout

    var pixelBuffer: CVPixelBuffer {
        retainedPixelBuffer.takeUnretainedValue()
    }

    init(retaining pixelBuffer: CVPixelBuffer, channelLayout: ChannelLayout = .bgra) {
        self.retainedPixelBuffer = Unmanaged.passRetained(pixelBuffer)
        self.channelLayout = channelLayout
    }

    deinit {
        retainedPixelBuffer.release()
    }
}

extension PlexStream {
    var isHDRVideo: Bool {
        let normalizedValues = [
            colorSpace,
            colorRange,
            colorPrimaries,
            colorTrc,
            profile,
        ]
            .compactMap { $0?.lowercased() }

        if normalizedValues.contains(where: { value in
            value.contains("2020") ||
            value.contains("bt.2020") ||
            value.contains("pq") ||
            value.contains("hlg") ||
            value.contains("hdr") ||
            value.contains("dovi") ||
            value.contains("dolby")
        }) {
            return true
        }

        return (bitDepth ?? 8) > 8
    }
}
