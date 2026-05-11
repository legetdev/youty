import Foundation
import AppKit

// Fast frame extraction pipeline.
//
// Stages:
//   1. ANDROID_VR InnerTube → list of formats (~250ms, 3s timeout)
//   2. Pick H.264 720p+ stream (<1ms)
//   3. Sequential 8MB Range download of full MP4 to temp file
//      (~1–10s, bandwidth-bound; first chunk has 5s timeout for instant fail)
//   4. Load the local file in a hidden WKWebView (~500ms)
//   5. Canvas-capture 100 frames with local seeks (~3–10s)
//   6. Write JPEGs to vault (~300ms)
//   7. Delete temp file
//
// Why WKWebView canvas on a local file instead of AVFoundation:
//   We verified that AVAssetImageGenerator, AVAssetReader, and
//   AVAssetExportSession all fail past the midpoint on YouTube's DASH-
//   fragmented H.264 streams (silent placeholder frames). WebKit's H.264
//   decoder handles these streams correctly — it's the same path YouTube.com
//   itself uses to play the video. Pointing it at a local file removes the
//   SABR network-seek bottleneck that makes the YouTube-canvas pipeline slow.
//
// On ANY failure: no fallback. Returns .failed(canFallback: true) so the
// caller can offer the canvas-on-YouTube fallback button to the user.

@MainActor
final class FastFramePipeline: FramePipeline {

    private let playerFetcher: PlayerFetcher
    private let parallelCapture: ParallelCapture
    private let vault: VaultManager

    private var currentStage: ((FrameStage) -> Void)?

    init(playerFetcher: PlayerFetcher,
         parallelCapture: ParallelCapture,
         vault: VaultManager) {
        self.playerFetcher = playerFetcher
        self.parallelCapture = parallelCapture
        self.vault = vault
    }

    private func emit(_ s: FrameStage) { currentStage?(s) }

    func extract(videoID: String,
                 folderURL: URL,
                 stage: @escaping (FrameStage) -> Void) async -> FramePipelineOutcome {

        currentStage = stage
        defer { currentStage = nil }

        let started = Date()
        var tempFileURL: URL?
        defer {
            if let url = tempFileURL {
                try? FileManager.default.removeItem(at: url)
                let html = url.deletingLastPathComponent().appendingPathComponent("player.html")
                try? FileManager.default.removeItem(at: html)
            }
        }

        DebugLog.log("=== FAST PATH START === videoID=\(videoID)")

        do {
            emit(.loading)

            // ---- Stage 1: format fetch ----
            let formatsStart = Date()
            let formatList = try await fetchFormatsWithFastFail(videoID: videoID)
            let formatsMs = Int(Date().timeIntervalSince(formatsStart) * 1000)
            DebugLog.log("fast: formats fetched in \(formatsMs)ms (n=\(formatList.formats.count), progressive=\(formatList.progressiveCount))")

            // ---- Stage 2: select stream ----
            let stream = try StreamFetcher.selectFastPathStream(
                from: formatList.formats,
                progressiveCount: formatList.progressiveCount)
            DebugLog.log("fast: selected codec=\(stream.codec) quality=\(stream.quality) size=\(stream.contentLength / 1_000_000)MB")

            // ---- Stage 3: download ----
            let ext = stream.mimeType.contains("webm") ? "webm" : "mp4"
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("youty-\(videoID)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let tempURL = tempDir.appendingPathComponent("video.\(ext)")
            tempFileURL = tempURL
            DebugLog.log("fast: download → \(tempURL.lastPathComponent)")

            let dlStart = Date()
            try await Downloader.download(stream: stream, to: tempURL) { p in
                Task { @MainActor [weak self] in self?.emit(.downloading(p)) }
            }
            let dlMs = Int(Date().timeIntervalSince(dlStart) * 1000)

            // ---- Stage 4: load local file into N parallel WKWebViews ----
            emit(.extracting(0))
            let loadStart = Date()
            try await parallelCapture.loadAllLocal(localURL: tempURL)
            let loadMs = Int(Date().timeIntervalSince(loadStart) * 1000)

            let trueDuration = formatList.lengthSeconds
            guard trueDuration > 0 else {
                throw FastPipelineError.videoLoadFailed
            }
            let timestamps = FrameExtractor.frameTimes(duration: trueDuration)
            DebugLog.log("fast: loaded \(parallelCapture.extractors.count) webviews in \(loadMs)ms, trueDuration=\(String(format: "%.1f", trueDuration))s, requesting \(timestamps.count) frames")

            // ---- Stage 5: parallel canvas capture ----
            let exStart = Date()
            let capturedTuples = try await parallelCapture.captureFrames(timestamps: timestamps) { p in
                Task { @MainActor [weak self] in self?.emit(.extracting(p)) }
            }
            let exMs = Int(Date().timeIntervalSince(exStart) * 1000)
            DebugLog.log("fast: captured \(capturedTuples.count)/\(timestamps.count) frames in \(exMs)ms (parallelism=\(parallelCapture.extractors.count))")
            let captured = capturedTuples

            guard captured.count == timestamps.count else {
                throw FastPipelineError.incompleteCapture(got: captured.count, expected: timestamps.count)
            }

            // ---- Stage 6: write ----
            emit(.writing)
            let frames = captured.map { FrameExtractor.Frame(timestamp: $0.0, image: $0.1) }
            let wrStart = Date()
            try vault.writeFrames(frames, to: folderURL)
            let wrMs = Int(Date().timeIntervalSince(wrStart) * 1000)

            let totalMs = Int(Date().timeIntervalSince(started) * 1000)
            DebugLog.log("=== FAST PATH SUCCESS === videoID=\(videoID) frames=\(frames.count) total=\(totalMs)ms (formats=\(formatsMs)ms download=\(dlMs)ms load=\(loadMs)ms capture=\(exMs)ms write=\(wrMs)ms)")

            return .success(framesWritten: frames.count, durationMs: totalMs, mode: "fast")

        } catch {
            let totalMs = Int(Date().timeIntervalSince(started) * 1000)
            let reason  = userMessage(for: error)
            DebugLog.log("=== FAST PATH FAILED === videoID=\(videoID) reason=\"\(reason)\" elapsed=\(totalMs)ms (raw: \(error))")
            return .failed(reason: reason, canFallback: true)
        }
    }

    // MARK: - Errors

    private enum FastPipelineError: LocalizedError {
        case videoLoadFailed
        case incompleteCapture(got: Int, expected: Int)

        var errorDescription: String? {
            switch self {
            case .videoLoadFailed:
                return "Could not load video in extraction engine."
            case .incompleteCapture(let g, let e):
                return "Captured only \(g) of \(e) frames."
            }
        }
    }

    // MARK: - Format fetch with fast-fail timeouts

    private func fetchFormatsWithFastFail(videoID: String) async throws -> StreamFetcher.FormatList {
        let visitorData = try await StreamFetcher.getVisitorData()
        do {
            return try await StreamFetcher.fetchFormats(videoID: videoID, visitorData: visitorData)
        } catch StreamFetchError.visitorDataInvalid {
            DebugLog.log("fast: visitor data invalid → refresh + retry")
            StreamFetcher.invalidateVisitorData()
            let fresh = try await StreamFetcher.getVisitorData()
            do {
                return try await StreamFetcher.fetchFormats(videoID: videoID, visitorData: fresh)
            } catch StreamFetchError.restrictedVideo {
                DebugLog.log("fast: restricted → trying PlayerFetcher (cookied retry)")
                return try await playerFetcher.fetchFormats(videoID: videoID)
            }
        } catch StreamFetchError.restrictedVideo {
            DebugLog.log("fast: restricted → trying PlayerFetcher (cookied retry)")
            return try await playerFetcher.fetchFormats(videoID: videoID)
        }
    }

    // MARK: - User-facing error messages

    private func userMessage(for error: Error) -> String {
        if let e = error as? StreamFetchError {
            switch e {
            case .noFastPathAvailable:
                return "Old or unusual upload — no H.264 720p stream available."
            case .restrictedVideo:
                return "Age-restricted or unavailable video."
            case .visitorDataInvalid:
                return "YouTube session expired."
            case .networkError(let code):
                if code == 401 || code == 403 {
                    return "YouTube client signature broken — fast path needs an update."
                }
                if code == 0 {
                    return "Network timeout reaching YouTube."
                }
                return "YouTube returned HTTP \(code)."
            case .parseError:
                return "Could not parse YouTube response."
            }
        }
        if let e = error as? DownloadError {
            switch e {
            case .firstChunkTimeout:
                return "Stream URL unreachable — client signature may be broken."
            case .httpError(let code):
                if code == 403 { return "Video blocked by YouTube (signature broken or geo-restricted)." }
                return "Download failed (HTTP \(code))."
            case .chunkTimeout(let mb):
                return "Video download stalled at \(mb) MB."
            case .zeroBytes:
                return "googlevideo returned an empty response."
            case .cancelled:
                return "Cancelled."
            }
        }
        if let e = error as? FastPipelineError { return e.localizedDescription }
        if error is TimeoutError                { return "Fast path timed out." }
        return error.localizedDescription
    }
}
