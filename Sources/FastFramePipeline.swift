import Foundation
import AppKit

// Fast frame extraction pipeline (Phase D — FFmpeg + custom AVIO).
//
// 1. ANDROID_VR InnerTube → stream URL  (~300 ms, 3 s timeout)
// 2. Pick H.264 / VP9 / AV1 at 1080p (or highest available)  (<1 ms)
// 3. FFmpeg byte-range fetches + decodes via libavformat / libavcodec
//    through a URLSession-backed AVIOContext (HTTP Range via URLSession's
//    HTTP/2 stack — fast on googlevideo, no file written to disk).
//    For dense targets (≤ 5 s apart on average): one linear pass.
//    For sparse targets: per-target seek + decode-the-keyframe.
// 4. Write JPEGs to vault (timestamp-in-ms filenames)
//
// On PoToken / age-restricted detection: returns .failed(canFallback: true)
// so ContentView routes to canvas-on-YouTube (existing ParallelCapture
// pointed at the YouTube watch URL). The slow canvas path is the safety
// net for the ~1 % of videos FFmpeg-via-ANDROID_VR can't reach.

@MainActor
final class FastFramePipeline: FramePipeline {

    private let playerFetcher: PlayerFetcher
    private let vault: VaultManager

    private var currentStage: ((FrameStage) -> Void)?

    init(playerFetcher: PlayerFetcher,
         vault: VaultManager) {
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
        DebugLog.log("=== FAST PATH START (ffmpeg) === videoID=\(videoID)")

        do {
            emit(.loading)

            // ---- Stage 1: format fetch ----
            let formatsStart = Date()
            let formatList = try await fetchFormatsWithFastFail(videoID: videoID)
            let formatsMs = Int(Date().timeIntervalSince(formatsStart) * 1000)
            DebugLog.log("fast: formats fetched in \(formatsMs)ms (n=\(formatList.formats.count), progressive=\(formatList.progressiveCount), length=\(formatList.lengthSeconds)s)")

            // ---- Stage 2: select stream ----
            let stream = try StreamFetcher.selectFastPathStream(
                from: formatList.formats,
                progressiveCount: formatList.progressiveCount)
            DebugLog.log("fast: selected codec=\(stream.codec) quality=\(stream.quality) size=\(stream.contentLength / 1_000_000)MB")

            // ---- Stage 3: extract frames via FFmpeg ----
            let trueDuration = formatList.lengthSeconds
            guard trueDuration > 0 else { throw FastPipelineError.noDuration }
            let timestamps = FrameExtractor.frameTimes(duration: trueDuration)
            DebugLog.log("fast: requesting \(timestamps.count) frames over \(String(format: "%.1f", trueDuration))s")

            emit(.extracting(0))
            let exStart = Date()
            let frames = try await FFmpegFrameExtractor.extract(
                url: stream.url,
                userAgent: StreamFetcher.androidVRUA,
                timestamps: timestamps,
                maxLongEdge: maxEdgeFor(quality: stream.quality),
                progress: { p in
                    Task { @MainActor [weak self] in self?.emit(.extracting(p)) }
                }
            )
            let exMs = Int(Date().timeIntervalSince(exStart) * 1000)
            DebugLog.log("fast: ffmpeg extracted \(frames.count)/\(timestamps.count) frames in \(exMs)ms")

            guard frames.count == timestamps.count else {
                throw FastPipelineError.incompleteCapture(got: frames.count, expected: timestamps.count)
            }

            // ---- Stage 4: write ----
            emit(.writing)
            let extractorFrames = frames.map {
                FrameExtractor.Frame(timestamp: $0.timestamp, image: $0.image)
            }
            let wrStart = Date()
            try vault.writeFrames(extractorFrames, to: folderURL)
            let wrMs = Int(Date().timeIntervalSince(wrStart) * 1000)

            let totalMs = Int(Date().timeIntervalSince(started) * 1000)
            DebugLog.log("=== FAST PATH SUCCESS === videoID=\(videoID) frames=\(frames.count) total=\(totalMs)ms (formats=\(formatsMs)ms ffmpeg=\(exMs)ms write=\(wrMs)ms)")

            return .success(framesWritten: frames.count, durationMs: totalMs, mode: "fast")

        } catch {
            let totalMs = Int(Date().timeIntervalSince(started) * 1000)
            let reason  = userMessage(for: error)
            DebugLog.log("=== FAST PATH FAILED === videoID=\(videoID) reason=\"\(reason)\" elapsed=\(totalMs)ms (raw: \(error))")
            return .failed(reason: reason, canFallback: true)
        }
    }

    // MARK: - Resolution policy

    // maxLongEdge for FFmpeg's BGRA output. We cap at the chosen quality's
    // long edge to avoid wasted memory / pixels, but always save at the
    // chosen source's native resolution — no upscaling.
    private func maxEdgeFor(quality: String) -> Int32 {
        switch quality {
        case "2160p": return 3840
        case "1440p": return 2560
        case "1080p": return 1920
        case "720p":  return 1280
        case "480p":  return 854
        case "360p":  return 640
        case "240p":  return 426
        case "144p":  return 256
        default:      return 1920
        }
    }

    // MARK: - Errors

    private enum FastPipelineError: LocalizedError {
        case noDuration
        case incompleteCapture(got: Int, expected: Int)

        var errorDescription: String? {
            switch self {
            case .noDuration:
                return "Video duration unknown — cannot compute frame timestamps."
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
                return "No supported codec found for this video."
            case .restrictedVideo:
                return "Age-restricted, members-only, or PoToken-gated video."
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
        if let e = error as? FFmpegError { return e.localizedDescription }
        if let e = error as? FastPipelineError { return e.localizedDescription }
        if error is TimeoutError { return "Fast path timed out." }
        return error.localizedDescription
    }
}
