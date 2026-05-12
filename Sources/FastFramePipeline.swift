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
    private let settings: SettingsStore

    private var currentStage: ((FrameStage) -> Void)?

    init(playerFetcher: PlayerFetcher,
         vault: VaultManager,
         settings: SettingsStore) {
        self.playerFetcher = playerFetcher
        self.vault = vault
        self.settings = settings
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
            let timestamps = FrameExtractor.frameTimes(
                duration: trueDuration,
                countCap: settings.frameCountCap,
                fpsCap: settings.fpsCap
            )
            DebugLog.log("fast: requesting \(timestamps.count) frames over \(String(format: "%.1f", trueDuration))s (cap=\(settings.frameCountCap) fps=\(settings.fpsCap))")

            emit(.extracting(0))
            let exStart = Date()
            let progressEmit: @Sendable (Double) -> Void = { [weak self] p in
                Task { @MainActor [weak self] in self?.emit(.extracting(p)) }
            }
            // Phase I: sample-precise byte fetch + stateless VTDecompressionSession.
            // Empirically:
            //  - long videos (≥ 8 min)        : ~2× faster than F.1.
            //  - large streams (≥ 40 MB)      : 1.1–1.2× faster.
            //  - small low-bitrate clips      : F.1 wins (its chunked LRU is
            //    more efficient when every DASH segment must be touched anyway).
            // The gate below preempts the loss case before paying Phase I's
            // setup cost. On any error Phase I throws → caller falls back.
            let usePhaseI = shouldTryPhaseI(stream: stream, duration: trueDuration)
            let frames: [(timestamp: TimeInterval, image: NSImage)]
            if usePhaseI {
                do {
                    frames = try await PhaseIFrameExtractor.extract(
                        url: stream.url,
                        userAgent: StreamFetcher.androidVRUA,
                        timestamps: timestamps,
                        maxLongEdge: maxEdgeFor(quality: stream.quality),
                        progress: progressEmit
                    )
                    DebugLog.log("fast: phase-I extracted \(frames.count)/\(timestamps.count) frames")
                } catch {
                    DebugLog.log("fast: phase-I failed (\(error.localizedDescription)) — falling back to F.1")
                    frames = try await FFmpegFrameExtractor.extract(
                        url: stream.url,
                        userAgent: StreamFetcher.androidVRUA,
                        timestamps: timestamps,
                        maxLongEdge: maxEdgeFor(quality: stream.quality),
                        progress: progressEmit
                    )
                    DebugLog.log("fast: F.1 fallback extracted \(frames.count)/\(timestamps.count) frames")
                }
            } else {
                DebugLog.log("fast: small stream (\(stream.contentLength / 1_000_000)MB / \(Int(trueDuration))s) — using F.1 directly")
                frames = try await FFmpegFrameExtractor.extract(
                    url: stream.url,
                    userAgent: StreamFetcher.androidVRUA,
                    timestamps: timestamps,
                    maxLongEdge: maxEdgeFor(quality: stream.quality),
                    progress: progressEmit
                )
            }
            let exMs = Int(Date().timeIntervalSince(exStart) * 1000)
            DebugLog.log("fast: extract phase \(exMs)ms")

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

    // MARK: - Phase I gate

    // Returns true when Phase I is expected to beat F.1. Empirically:
    //  - Phase I wins on long + low-bitrate content (Karpathy 220 MB / 116 min,
    //    1080p, 31 KB/s → 23 s F.1 vs 11 s Phase I).
    //  - Phase I loses on high-bitrate content where every touched segment is
    //    large (Freerunning 1.4 GB / 36 min, 1080p60, 653 KB/s → 20 s F.1 vs
    //    26 s Phase I). F.1's chunked LRU batches large contiguous reads more
    //    efficiently than Phase I's per-segment two-step fetch.
    //  - Phase I loses on small/dense content where every segment is touched
    //    anyway (the 22 MB / 5 min / 75 KB/s case).
    private func shouldTryPhaseI(stream: VideoStream, duration: TimeInterval) -> Bool {
        // Small / short clips: F.1's contiguous chunked path wins.
        if duration < 480 && stream.contentLength < 40_000_000 { return false }
        // High-bitrate streams (1080p60 HFR, 4K, dense action footage): F.1
        // also wins. Threshold derived from Rick (375 KB/s) and Gangnam
        // (428 KB/s) where Phase I was marginally better vs Freerunning
        // (653 KB/s) where Phase I lost by 5 s.
        if duration > 0 {
            let bitrate = Double(stream.contentLength) / duration
            if bitrate > 500_000 { return false }
        }
        return true
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
