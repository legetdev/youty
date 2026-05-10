import Foundation
import AppKit
import AVFoundation

// SIDELINED — not currently wired into ContentView.
//
// To re-enable, in ContentView.runFramePipeline replace
//   CanvasFramePipeline(canvasExtractor:..., vault:...)
// with
//   FastFramePipeline(canvas: CanvasFramePipeline(...), playerFetcher:..., vault:...)
//
// What it does:
//   1. ANDROID_VR InnerTube → signed H.264 720p stream URL (~500 ms)
//   2. AVURLAsset(url: streamURL) with ANDROID_VR User-Agent — no download
//   3. AVAssetImageGenerator.generateCGImagesAsynchronously with ±2s tolerance
//   4. AVFoundation issues HTTP Range requests for keyframe bytes only
//      (~20–50 MB total regardless of video length)
//   5. On any failure → delegates to the wrapped CanvasFramePipeline
//
// Why sidelined (2026-05-10):
//   AVURLAsset against googlevideo signed URLs hangs on duration load even
//   with the correct ANDROID_VR User-Agent. Symptom: TLS handshake completes,
//   no body bytes ever arrive, request stalls indefinitely (20s timeout fires).
//   Root cause unknown — could be regional throttling, signed-URL handling
//   in CoreMedia, or anti-abuse on googlevideo. Needs further investigation
//   before it can be the default path.

@MainActor
final class FastFramePipeline: FramePipeline {

    private let canvas: CanvasFramePipeline
    private let playerFetcher: PlayerFetcher
    private let vault: VaultManager

    // Holds the active stage callback for the duration of one extract() call.
    // Stored on this @MainActor object so @Sendable inner closures can hop
    // back to main and call it without capturing a non-Sendable value.
    private var currentStage: ((FrameStage) -> Void)?

    init(canvas: CanvasFramePipeline,
         playerFetcher: PlayerFetcher,
         vault: VaultManager) {
        self.canvas = canvas
        self.playerFetcher = playerFetcher
        self.vault = vault
    }

    private func emit(_ s: FrameStage) { currentStage?(s) }

    func extract(videoID: String,
                 folderURL: URL,
                 stage: @escaping (FrameStage) -> Void) async -> FramePipelineOutcome {

        currentStage = stage
        defer { currentStage = nil }

        let started = Date()
        DebugLog.log("fast pipeline: \(videoID)")

        do {
            emit(.loading)

            // 1. Stream URL
            DebugLog.log("fast: fetching formats")
            let formats = try await fetchFormatsWithFallback(videoID: videoID)
            let stream  = try StreamFetcher.selectFastPathStream(from: formats)
            DebugLog.log("fast: selected \(stream.codec) \(stream.quality), \(stream.contentLength / 1_000_000)MB")

            // 2. Load remote asset (with timeout)
            emit(.extracting(0))
            let asset = FastFrameExtractor.makeAsset(url: stream.url)
            let durationCM: CMTime
            do {
                durationCM = try await withTimeout(seconds: 20) {
                    try await asset.load(.duration)
                }
            } catch {
                DebugLog.log("fast: duration load timed out — \(error.localizedDescription)")
                throw FastPathError.networkUnreachable
            }
            let duration = CMTimeGetSeconds(durationCM)
            guard duration > 0 else { throw FastPathError.networkUnreachable }

            // 3. Extract frames via Range-streamed AVFoundation
            let timestamps = FrameExtractor.frameTimes(duration: duration)
            DebugLog.log("fast: extracting \(timestamps.count) frames")
            let exStart = Date()
            let frames = try await FastFrameExtractor.extract(from: stream.url,
                                                              timestamps: timestamps) { p in
                Task { @MainActor [weak self] in self?.emit(.extracting(p)) }
            }
            DebugLog.log("fast: \(frames.count) frames in \(Int(Date().timeIntervalSince(exStart) * 1000))ms")

            // Underdelivery check
            let expected = timestamps.count
            if Double(frames.count) < FastFrameExtractor.underdeliveryThreshold * Double(expected) {
                throw FastPathError.underdelivered
            }

            emit(.writing)
            try vault.writeFrames(frames, to: folderURL)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            DebugLog.log("fast COMPLETE: \(frames.count) frames in \(ms)ms")
            return .success(framesWritten: frames.count, durationMs: ms, mode: "fast")

        } catch {
            DebugLog.log("fast failed: \(error.localizedDescription) — delegating to canvas")
            return await canvas.extract(videoID: videoID, folderURL: folderURL, stage: stage)
        }
    }

    // MARK: - Internals

    private enum FastPathError: LocalizedError {
        case networkUnreachable
        case underdelivered

        var errorDescription: String? {
            switch self {
            case .networkUnreachable: return "Could not reach stream URL."
            case .underdelivered:     return "Fast path delivered too few frames."
            }
        }
    }

    private func fetchFormatsWithFallback(videoID: String) async throws -> [[String: Any]] {
        var visitorData = try await StreamFetcher.getVisitorData()
        do {
            return try await StreamFetcher.fetchFormats(videoID: videoID, visitorData: visitorData)
        } catch StreamFetchError.visitorDataInvalid {
            StreamFetcher.invalidateVisitorData()
            visitorData = try await StreamFetcher.getVisitorData()
            do {
                return try await StreamFetcher.fetchFormats(videoID: videoID, visitorData: visitorData)
            } catch StreamFetchError.restrictedVideo {
                return try await playerFetcher.fetchFormats(videoID: videoID)
            }
        } catch StreamFetchError.restrictedVideo {
            return try await playerFetcher.fetchFormats(videoID: videoID)
        }
    }
}
