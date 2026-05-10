import Foundation
import AppKit

// The currently-active frame pipeline.
//
// Loads the YouTube page in a hidden WKWebView (VideoExtractor), forces 720p,
// then seeks and canvas-captures each requested timestamp. Slow (~30s for short
// videos, several minutes for long ones) but reliable across all videos and
// all network conditions because it uses the same playback path as the browser.

@MainActor
final class CanvasFramePipeline: FramePipeline {

    private let canvasExtractor: VideoExtractor
    private let vault: VaultManager

    init(canvasExtractor: VideoExtractor, vault: VaultManager) {
        self.canvasExtractor = canvasExtractor
        self.vault = vault
    }

    func extract(videoID: String,
                 folderURL: URL,
                 stage: @escaping (FrameStage) -> Void) async -> FramePipelineOutcome {

        let started = Date()
        DebugLog.log("canvas pipeline: \(videoID)")

        do {
            stage(.loading)
            try await canvasExtractor.loadVideo(videoID: videoID)

            let duration = await canvasExtractor.getVideoDuration()
            guard duration > 0 else {
                return .failed("Could not determine video duration.")
            }

            let timestamps = FrameExtractor.frameTimes(duration: duration)
            DebugLog.log("canvas: extracting \(timestamps.count) frames over \(Int(duration))s")

            let captured = try await canvasExtractor.captureFrames(timestamps: timestamps) { p in
                stage(.extracting(p))
            }
            let frames = captured.map { FrameExtractor.Frame(timestamp: $0.0, image: $0.1) }

            guard !frames.isEmpty else {
                return .failed("Canvas extraction produced 0 frames.")
            }

            stage(.writing)
            try vault.writeFrames(frames, to: folderURL)

            let ms = Int(Date().timeIntervalSince(started) * 1000)
            DebugLog.log("canvas COMPLETE: \(frames.count) frames in \(ms)ms")
            return .success(framesWritten: frames.count, durationMs: ms, mode: "canvas")

        } catch {
            DebugLog.log("canvas FAILED: \(error.localizedDescription)")
            return .failed(error.localizedDescription)
        }
    }
}
