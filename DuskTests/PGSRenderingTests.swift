import Foundation
import CoreVideo
import UIKit
import SwiftUI
import Testing
#if os(tvOS)
import TVVLCKit
#else
import MobileVLCKit
#endif
@testable import Dusk

@Suite("PGS rendering", .serialized)
@MainActor
struct PGSRenderingTests {
    @Test(arguments: [0, 1])
    func embeddedSubtitlesSurviveLateBlendingAndTrackChanges(subtitlePosition: Int) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("late-spu-\(UUID()).mkv")
        try Data(base64Encoded: Self.fixture)!.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let player = VLCMediaPlayer(library: VLCLibrary(options: ["--no-video-title-show"]))
        let sink = PGSFrameSink()
        let output = DuskVLCRawVideoOutput(frameConsumer: sink)
        output.requiresLateSubtitleBlending = true
        #expect(output.attach(to: player))
        let style = VLCTextRendererStyle(caption: .current(for: .dusk), size: .default)
        _ = DuskVLCTextRenderer.setString(style.font, forOption: "freetype-font", on: player)
        for (option, value) in style.integers {
            _ = DuskVLCTextRenderer.setInteger(Int64(value), forOption: option, on: player)
        }
        let media = VLCMedia(url: url)
        media.addOption(":sub-track=\(subtitlePosition)")
        player.media = media
        player.audio?.isMuted = true
        player.play()
        defer { player.stop(); output.detach() }

        // Preselect before demuxing: tiny files can otherwise read the first
        // subtitle packet before the runtime track list becomes available.
        try await Task.sleep(for: .seconds(2))
        let selectedID = player.currentVideoSubTitleIndex
        #expect(selectedID >= 0)
        #expect(sink.counts.frames > 0)
        #expect(sink.counts.bright > 0)
        // Decoder buffers can include alignment padding beyond the visible
        // 192×144 image; the negotiated output must exceed that area.
        #expect(sink.size.width > 192)
        #expect(sink.size.height > 144)

        player.currentVideoSubTitleIndex = -1
        player.time = VLCTime(int: 0)
        try await Task.sleep(for: .milliseconds(500))
        sink.reset()
        try await Task.sleep(for: .seconds(2))
        #expect(sink.counts.frames > 0)
        #expect(sink.counts.bright == 0)

        player.currentVideoSubTitleIndex = selectedID
        // Re-read the cue after switching: libvlc may have demuxed it ahead
        // while Off, even though playback has not reached its timestamp.
        player.time = VLCTime(int: 0)
        try await Task.sleep(for: .milliseconds(500))
        sink.reset()
        try await Task.sleep(for: .seconds(2))
        #expect(player.currentVideoSubTitleIndex == selectedID)
        #expect(sink.counts.bright > 0)
    }
    @Test func subtitlesOffKeepsDecoderGeometry() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("no-spu-\(UUID()).mkv")
        try Data(base64Encoded: Self.fixture)!.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        var originalSize: CGSize?
        for lateBlend in [false, true] {
            let player = VLCMediaPlayer(library: VLCLibrary(options: ["--no-video-title-show"]))
            let sink = PGSFrameSink()
            let output = DuskVLCRawVideoOutput(frameConsumer: sink)
            #expect(!output.requiresLateSubtitleBlending)
            output.requiresLateSubtitleBlending = lateBlend
            #expect(output.attach(to: player))
            let media = VLCMedia(url: url)
            media.addOption(":no-spu")
            player.media = media
            player.play()
            defer { player.stop(); output.detach() }
            try await Task.sleep(for: .seconds(2))
            #expect(sink.counts.frames > 0)
            #expect(sink.counts.bright == 0)
            if let originalSize {
                #expect(sink.size.width == originalSize.width + 1)
                #expect(sink.size.height == originalSize.height + 1)
            } else {
                #expect(sink.size.width == 192)
                originalSize = sink.size
            }
        }
    }

    @Test(arguments: [0, 1], [false, true])
    func nativeSubtitleFallbackRetainsSelectionAndClock(subtitlePosition: Int, paused: Bool) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("native-spu-\(UUID()).mkv")
        try Data(base64Encoded: Self.fixture)!.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = VLCKitEngine()
        let request = VideoEnhancementRequest(mode: .enabled, sourceWidth: 192, sourceHeight: 144)
        engine.configureVideoEnhancement(request)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView: engine.makePlayerView().ignoresSafeArea())
        window.rootViewController = controller
        window.makeKeyAndVisible()
        let context = PlaybackAttemptContext(attemptID: UUID(), title: "Subtitle fixture", ratingKey: "1", engine: .vlcKit,
            resolverReason: "Subtitle regression", mediaID: 1, partID: 1, sanitizedPlaybackURL: "local fixture")
        let source = PlaybackSource(url: url, startPosition: nil, context: context)
        engine.load(source: source)
        engine.selectSubtitleTrack(nil)
        defer { engine.stop(); window.isHidden = true }
        try await waitUntil { engine.state == .playing && engine.availableSubtitleTracks.count == 2 }
        #expect(!engine.videoEnhancementStatus.reason.contains("Native VLC"))
        engine.seek(to: 4)
        try await waitUntil { engine.currentTime >= 4 }
        if paused { engine.pause() }
        let generation = engine.playerViewGeneration
        let track = engine.availableSubtitleTracks[subtitlePosition]
        engine.selectSubtitleTrack(track)
        controller.rootView = engine.makePlayerView().ignoresSafeArea()
        try await waitUntil {
            engine.state == (paused ? .paused : .playing) &&
                engine.playerViewGeneration > generation && engine.selectedSubtitleTrackID == track.id
        }
        #expect(engine.currentTime >= 3)
        #expect(engine.videoEnhancementStatus.state == .disabled)
        #expect(engine.videoEnhancementStatus.reason.contains("Native VLC"))
        engine.selectSubtitleTrack(nil)
        try await waitUntil { engine.selectedSubtitleTrackID == nil }
        #expect(engine.playerViewGeneration == generation + 1)
        #expect(engine.videoEnhancementStatus.reason.contains("Native VLC"))
        // Reusing the engine for another item restores the untouched raw path.
        engine.load(source: source)
        engine.selectSubtitleTrack(nil)
        controller.rootView = engine.makePlayerView().ignoresSafeArea()
        try await waitUntil { engine.state == .playing && !engine.availableSubtitleTracks.isEmpty }
        #expect(!engine.videoEnhancementStatus.reason.contains("Native VLC"))
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        try #require(condition(), "Timed out waiting for VLC subtitle transition")
    }

    // Synthetic black H.264 with embedded PGS (white rectangle) and SRT
    // ("Dusk embedded text") at 1–3, 4–6 and 7–9 seconds. No audio/Plex/media.
    private static let fixture = "GkXfo6NChoEBQveBAULygQRC84EIQoKIbWF0cm9za2FCh4EEQoWBAhhTgGcBAAAAAAAVsxFNm3TAv4SKUiH0TbuLU6uEFUmpZlOsgaFNu4tTq4QWVK5rU6yB7027jFOrhBJUw2dTrIIB9U27jFOrhBxTu2tTrIIU8uwBAAAAAAAAUwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAFUmpZsm/hDfv5A4q17GDD0JATYCMTGF2ZjYzLjEuMTAyV0GMTGF2ZjYzLjEuMTAyc6SQ5eGsmTmAuOwhm+cUDt/qrESJiEDTiAAAAAAAFlSua0EAv4T6Ffu6rgEAAAAAAACB14EBc8WIEIHbatocmZqcgQAitZyDdW5kiIEAho9WX01QRUc0L0lTTy9BVkODgQEj44OEBfXhAOCQsIHAuoGQmoECVbCEVbmBAVXugQDsAQAAAAAAAAIAAGOipgFCwAv/4QAXZ0LAC9oME7ARAAADAAEAAAMAFA8UKqABAARozgRyrgEAAAAAAAAv14ECc8WIFFzzqH90ejacgQAitZyDdW5kVaqBAYaKU19IRE1WL1BHU4OBEVXugQCuAQAAAAAAAC/XgQNzxYimwi9XxIB1x5yBACK1nIN1bmSIgQCGi1NfVEVYVC9VVEY4g4ERVe6BABJUw2dA67+ERcIAWXNzn2PAgGfImUWjh0VOQ09ERVJEh4xMYXZmNjMuMS4xMDJzc9ZjwItjxYgQgdtq2hyZmmfIoUWjh0VOQ09ERVJEh5RMYXZjNjMuMS4xMDIgbGlieDI2NGfIoUWjiERVUkFUSU9ORIeTMDA6MDA6MjAuMDAwMDAwMDAwAHNzsmPAi2PFiBRc86h/dHo2Z8ihRaOIRFVSQVRJT05Eh5MwMDowMDowOS4wMDAwMDAwMDAAc3OyY8CLY8WIpsIvV8SAdcdnyKFFo4hEVVJBVElPTkSHkzAwOjAwOjA5LjAwMDAwMDAwMAAfQ7Z1R5C/hAfrInjngQCjQr2BAACAAAACVAYF//9Q3EXpvebZSLeWLNgg2SPu73gyNjQgLSBjb3JlIDE2NSByMzIyMiBiMzU2MDVhIC0gSC4yNjQvTVBFRy00IEFWQyBjb2RlYyAtIENvcHlsZWZ0IDIwMDMtMjAyNSAtIGh0dHA6Ly93d3cudmlkZW9sYW4ub3JnL3gyNjQuaHRtbCAtIG9wdGlvbnM6IGNhYmFjPTAgcmVmPTEgZGVibG9jaz0wOjA6MCBhbmFseXNlPTA6MCBtZT1kaWEgc3VibWU9MCBwc3k9MSBwc3lfcmQ9MS4wMDowLjAwIG1peGVkX3JlZj0wIG1lX3JhbmdlPTE2IGNocm9tYV9tZT0xIHRyZWxsaXM9MCA4eDhkY3Q9MCBjcW09MCBkZWFkem9uZT0yMSwxMSBmYXN0X3Bza2lwPTEgY2hyb21hX3FwX29mZnNldD0wIHRocmVhZHM9NCBsb29rYWhlYWRfdGhyZWFkcz0xIHNsaWNlZF90aHJlYWRzPTAgbnI9MCBkZWNpbWF0ZT0xIGludGVybGFjZWQ9MCBibHVyYXlfY29tcGF0PTAgY29uc3RyYWluZWRfaW50cmE9MCBiZnJhbWVzPTAgd2VpZ2h0cD0wIGtleWludD0yNTAga2V5aW50X21pbj0xMCBzY2VuZWN1dD0wIGludHJhX3JlZnJlc2g9MCByYz1jcmYgbWJ0cmVlPTAgY3JmPTMwLjAgcWNvbXA9MC42MCBxcG1pbj0wIHFwbWF4PTY5IHFwc3RlcD00IGlwX3JhdGlvPTEuNDAgYXE9MACAAAAAXWWIhDomKAAIb8nJycnJycnJycnJ1111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111114KOOgQBkAAAAAAZBmiA6gNujjoEAyAAAAAAGQZpAOoDbo46BASwAAAAABkGaYD6A26OOgQGQAAAAAAZBmoA+gNujjoEB9AAAAAAGQZqgPoDbo46BAlgAAAAABkGawD6A26OOgQK8AAAAAAZBmuA+gNujjoEDIAAAAAAGQZsAPoDbo46BA4QAAAAABkGbID6A26OOgQPoAAAAAAZBm0A+gNujQKeCA+iAFgATAMAAkBAAAIAAAAEAAAAAACAAcBcACgEAACAAcABAABAUAAwAAAAQgIAAAeuAgP8VAGsAAADAAABkAEAAEADAQAEAAADAQAEAAADAQAEAAADAQAEAAADAQAEAAADAQAEAAADAQAEAAADAQAEAAADAQAEAAADAQAEAAADAQAEAAADAQAEAAADAQAEAAADAQAEAAADAQAEAAADAQAEAAIAAAKCcoZaDA+gARHVzayBlbWJlZGRlZCB0ZXh0m4IH0KOOgQRMAAAAAAZBm2A+gNujjoEEsAAAAAAGQZuAPoDbo46BBRQAAAAABkGboD6A26OOgQV4AAAAAAZBm8A+gNujjoEF3AAAAAAGQZvgPoDbo46BBkAAAAAABkGaAD6A26OOgQakAAAAAAZBmiA+gNujjoEHCAAAAAAGQZpAPoDbo46BB2wAAAAABkGaYD6A26OOgQfQAAAAAAZBmoA+gNujjoEINAAAAAAGQZqgPoDbo46BCJgAAAAABkGawD6A26OOgQj8AAAAAAZBmuA+gNujjoEJYAAAAAAGQZsAPoDbo46BCcQAAAAABkGbID6A26OOgQooAAAAAAZBm0A+gNujjoEKjAAAAAAGQZtgPoDbo46BCvAAAAAABkGbgD6A26OOgQtUAAAAAAZBm6A+gNujjoELuAAAAAAGQZvAPoDbo5WCC7iAFgALAMAAkBAAAQAAAACAAACjjoEMHAAAAAAGQZvgPoDbo46BDIAAAAAABkGaAD6A26OOgQzkAAAAAAZBmiA+gNujjoENSAAAAAAGQZpAPoDbo46BDawAAAAABkGaYD6A26OOgQ4QAAAAAAZBmoA+gNujjoEOdAAAAAAGQZqgPoDbo46BDtgAAAAABkGawD6A26OOgQ88AAAAAAZBmuA+gNujjoEPoAAAAAAGQZsAPoDbo0Cngg+ggBYAEwDAAJAQAAKAAAABAAAAAAAgAHAXAAoBAAAgAHAAQAAQFAAMAAAAEICAAAHrgID/FQBrAAAAwAAAZABAABAAwEABAAAAwEABAAAAwEABAAAAwEABAAAAwEABAAAAwEABAAAAwEABAAAAwEABAAAAwEABAAAAwEABAAAAwEABAAAAwEABAAAAwEABAAAAwEABAAAAwEABAAAAwEABAACAAACgnKGWgw+gAER1c2sgZW1iZWRkZWQgdGV4dJuCB9CjjoEQBAAAAAAGQZsgPoDbo46BEGgAAAAABkGbQD6A26OOgRDMAAAAAAZBm2A+gNujjoERMAAAAAAGQZuAPoDbo46BEZQAAAAABkGboD6A26OOgRH4AAAAAAZBm8A+gNujjoESXAAAAAAGQZvgPoDbo46BEsAAAAAABkGaAD6A26OOgRMkAAAAAAZBmiA+gNujjoETiAAAAAAGQZpAPoDbH0O2dUQwv4RviLfc54IT7KOOgQAAAAAAAAZBmmA+gNujjoEAZAAAAAAGQZqAPoDbo46BAMgAAAAABkGaoD6A26OOgQEsAAAAAAZBmsA+gNujjoEBkAAAAAAGQZrgPoDbo46BAfQAAAAABkGbAD6A26OOgQJYAAAAAAZBmyA+gNujjoECvAAAAAAGQZtAPoDbo46BAyAAAAAABkGbYD6A26OOgQOEAAAAAAZBm4A+gNujlYIDhIAWAAsAwACQEAADAAAAAIAAAKOOgQPoAAAAAAZBm6A+gNujjoEETAAAAAAGQZvAPoDbo46BBLAAAAAABkGb4D6A26OOgQUUAAAAAAZBmgA+gNujjoEFeAAAAAAGQZogPoDbo46BBdwAAAAABkGaQD6A26OOgQZAAAAAAAZBmmA+gNujjoEGpAAAAAAGQZqAPoDbo46BBwgAAAAABkGaoD6A26OOgQdsAAAAAAZBmsA+gNujQKeCB2yAFgATAMAAkBAABIAAAAEAAAAAACAAcBcACgEAACAAcABAABAUAAwAAAAQgIAAAeuAgP8VAGsAAADAAABkAEAAEADAQAEAAADAQAEAAADAQAEAAADAQAEAAADAQAEAAADAQAEAAADAQAEAAADAQAEAAADAQAEAAADAQAEAAADAQAEAAADAQAEAAADAQAEAAADAQAEAAADAQAEAAADAQAEAAIAAAKCcoZaDB2wARHVzayBlbWJlZGRlZCB0ZXh0m4IH0KOOgQfQAAAAAAZBmuA+gNujjoEINAAAAAAGQZsAPoDbo46BCJgAAAAABkGbID6A26OOgQj8AAAAAAZBm0A+gNujjoEJYAAAAAAGQZtgPoDbo46BCcQAAAAABkGbgD6A26OOgQooAAAAAAZBm6A+gNujjoEKjAAAAAAGQZvAPoDbo46BCvAAAAAABkGb4D6A26OOgQtUAAAAAAZBmgA+gNujjoELuAAAAAAGQZogPoDbo46BDBwAAAAABkGaQD6A26OOgQyAAAAAAAZBmmA+gNujjoEM5AAAAAAGQZqAPoDbo46BDUgAAAAABkGaoD6A26OOgQ2sAAAAAAZBmsA+gNujjoEOEAAAAAAGQZrgPoDbo46BDnQAAAAABkGbAD6A26OOgQ7YAAAAAAZBmyA+gNujjoEPPAAAAAAGQZtAPoDbo5WCDzyAFgALAMAAkBAABQAAAACAAACjjoEPoAAAAAAGQZtgPoDbo46BEAQAAAAABkGbgD6A26OOgRBoAAAAAAZBm6A+gNujjoEQzAAAAAAGQZvAPoDbo46BETAAAAAABkGb4D6A26OOgRGUAAAAAAZBmgA+gNujjoER+AAAAAAGQZogPoDbo46BElwAAAAABkGaQD6A26OOgRLAAAAAAAZBmmA+gNujjoETJAAAAAAGQZqAPoDbo46BE4gAAAAABkGaoD6A2x9DtnVDOr+EfDPaiOeCJ9ijjoEAAAAAAAAGQZrAPoDbo46BAGQAAAAABkGa4D6A26OOgQDIAAAAAAZBmwA+gNujjoEBLAAAAAAGQZsgPoDbo46BAZAAAAAABkGbQD6A26OOgQH0AAAAAAZBm2A+gNujjoECWAAAAAAGQZuAPoDbo46BArwAAAAABkGboD6A26OOgQMgAAAAAAZBm8A+gNujjoEDhAAAAAAGQZvgPoDbo46BA+gAAAAABkGaAD6A26OOgQRMAAAAAAZBmiA+gNujjoEEsAAAAAAGQZpAPoDbo46BBRQAAAAABkGaYD6A26OOgQV4AAAAAAZBmoA+gNujjoEF3AAAAAAGQZqgPoDbo46BBkAAAAAABkGawD6A26OOgQakAAAAAAZBmuA+gNujjoEHCAAAAAAGQZsAPoDbo46BB2wAAAAABkGbID6A26OOgQfQAAAAAAZBm0A+gNujjoEINAAAAAAGQZtgPoDbo46BCJgAAAAABkGbgD6A26OOgQj8AAAAAAZBm6A+gNujjoEJYAAAAAAGQZvAPoDbo46BCcQAAAAABkGb4D6A26OOgQooAAAAAAZBmgA+gNujjoEKjAAAAAAGQZogPoDbo46BCvAAAAAABkGaQD6A26OOgQtUAAAAAAZBmmA+gNujjoELuAAAAAAGQZqAPoDbo46BDBwAAAAABkGaoD6A26OOgQyAAAAAAAZBmsA+gNujjoEM5AAAAAAGQZrgPoDbo46BDUgAAAAABkGbAD6A26OOgQ2sAAAAAAZBmyA+gNujjoEOEAAAAAAGQZtAPoDbo46BDnQAAAAABkGbYD6A26OOgQ7YAAAAAAZBm4A+gNujjoEPPAAAAAAGQZugPoDbo46BD6AAAAAABkGbwD6A26OOgRAEAAAAAAZBm+A+gNujjoEQaAAAAAAGQZoAPoDbo46BEMwAAAAABkGaID6A26OOgREwAAAAAAZBmkA+gNujjoERlAAAAAAGQZpgPoDbo46BEfgAAAAABkGagD6A26OOgRJcAAAAAAZBmqA+gNujjoESwAAAAAAGQZrAPoDbo46BEyQAAAAABkGa4D6A26OOgROIAAAAAAZBmwA+gNsfQ7Z1Qvq/hLyQBX3ngjvEo46BAAAAAAAABkGbID6A26OOgQBkAAAAAAZBm0A+gNujjoEAyAAAAAAGQZtgPoDbo46BASwAAAAABkGbgD6A26OOgQGQAAAAAAZBm6A+gNujjoEB9AAAAAAGQZvAPoDbo46BAlgAAAAABkGb4D6A26OOgQK8AAAAAAZBmgA+gNujjoEDIAAAAAAGQZogPoDbo46BA4QAAAAABkGaQD6A26OOgQPoAAAAAAZBmmA+gNujjoEETAAAAAAGQZqAPoDbo46BBLAAAAAABkGaoD6A26OOgQUUAAAAAAZBmsA+gNujjoEFeAAAAAAGQZrgPoDbo46BBdwAAAAABkGbAD6A26OOgQZAAAAAAAZBmyA+gNujjoEGpAAAAAAGQZtAPoDbo46BBwgAAAAABkGbYD6A26OOgQdsAAAAAAZBm4A+gNujjoEH0AAAAAAGQZugPoDbo46BCDQAAAAABkGbwD6A26OOgQiYAAAAAAZBm+A+gNujjoEI/AAAAAAGQZoAPoDbo46BCWAAAAAABkGaID6A26OOgQnEAAAAAAZBmkA+gNujjoEKKAAAAAAGQZpgPoDbo46BCowAAAAABkGagD6A26OOgQrwAAAAAAZBmqA+gNujjoELVAAAAAAGQZrAPoDbo46BC7gAAAAABkGa4D6A26OOgQwcAAAAAAZBmwA+gNujjoEMgAAAAAAGQZsgPoDbo46BDOQAAAAABkGbQD6A26OOgQ1IAAAAAAZBm2A+gNujjoENrAAAAAAGQZuAPoDbo46BDhAAAAAABkGboD6A26OOgQ50AAAAAAZBm8A+gNujjoEO2AAAAAAGQZvgPoDbo46BDzwAAAAABkGaAD6A26OOgQ+gAAAAAAZBmiA+gNujjoEQBAAAAAAGQZpAPoDbo46BEGgAAAAABkGaYD6A26OOgRDMAAAAAAZBmoA+gNujjoERMAAAAAAGQZqgPoDbo46BEZQAAAAABkGawD6A26OOgRH4AAAAAAZBmuA+gNscU7trQLu/hLLCBlC7j7OBALeK94EB8YIC5vCBCbuis4ID6LeL94EC8YIC5vCCA2m3j/eBA/GCAubwggQTsoIH0LuRs4ILuLeL94EC8YIC5vCCBXG7orOCD6C3i/eBAvGCAubwggYot4/3gQPxggLm8IIG0rKCB9C7kLOCF3C3iveBAvGCCnzwgaq7orOCG1i3i/eBAvGCCnzwggFht4/3gQPxggp88IICC7KCB9C7kbOCIyi3i/eBAvGCCnzwggNp"

}

private final class PGSFrameSink: NSObject, DuskVLCVideoFrameConsumer, @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0
    private var bright = 0
    private var frameSize = CGSize.zero
    var size: CGSize { lock.withLock { frameSize } }
    func reset() { lock.withLock { frames = 0; bright = 0 } }
    var counts: (frames: Int, bright: Int) { lock.withLock { (frames, bright) } }
    func duskVLCVideoOutputDidProduce(_ buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let pitch = CVPixelBufferGetBytesPerRow(buffer)
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let value = (0..<CVPixelBufferGetHeight(buffer)).map { row in
            (0..<CVPixelBufferGetWidth(buffer)).map { base[row * pitch + $0 * 4] }.max() ?? 0
        }.max() ?? 0
        lock.withLock {
            frameSize = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
            frames += 1
            if value > 128 { bright += 1 }
        }
    }
}
