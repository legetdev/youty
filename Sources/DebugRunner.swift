import Foundation
import AppKit
import CryptoKit

// Headless verification harness. Bypasses the SwiftUI window so Phase I
// (and the production path) can be exercised against real YouTube URLs from
// the command line — the only way to honestly measure timing and verify
// distinct-frame counts without manual UI interaction.
//
// Invocation:
//   youty --extract <url> [--count N] [--out DIR] [--mode production|phase1]
//         [--max-edge N]
//
// Output to stdout (machine-readable):
//   MODE=phase1
//   VIDEO_ID=dQw4w9WgXcQ
//   DURATION_S=212.0
//   STREAM_QUALITY=1080p
//   STREAM_CODEC=H264
//   STREAM_BYTES=83217829
//   FRAMES_REQUESTED=100
//   FRAMES_RETURNED=100
//   FRAMES_DISTINCT_SHA=98          // count of unique SHA-256 of JPEG bytes
//   PHASE_FORMATS_MS=312
//   PHASE_EXTRACT_MS=2841
//   PHASE_WRITE_MS=420
//   TOTAL_MS=3573
//   OUT_DIR=/tmp/.../...
//
// Exit codes:
//   0 — success: all frames returned + written.
//   1 — partial: extractor returned fewer frames than requested.
//   2 — setup error: formats fetch / stream selection failed.
//   3 — extraction error: extractor threw.

enum DebugRunner {

    static func shouldRun() -> Bool {
        CommandLine.arguments.contains("--extract")
            || CommandLine.arguments.contains("--tiktok-probe")
            || CommandLine.arguments.contains("--instagram-probe")
            || CommandLine.arguments.contains("--speech-probe")
            || CommandLine.arguments.contains("--shortform-save")
    }

    // Entry point called from AppEntry.main when --extract is in argv.
    // Calls exit() — never returns.
    static func run() -> Never {
        let args = CommandLine.arguments

        // Per-platform probes that bypass the YouTube-only flow above.
        if let probeURL = stringArg(args, key: "--tiktok-probe") {
            runTikTokProbe(urlString: probeURL)   // never returns
        }
        if let probeURL = stringArg(args, key: "--instagram-probe") {
            runInstagramProbe(urlString: probeURL)
        }
        if let audio = stringArg(args, key: "--speech-probe") {
            runSpeechProbe(audioPath: audio)
        }
        if let saveURL = stringArg(args, key: "--shortform-save") {
            runShortFormSaveProbe(urlString: saveURL,
                                   vaultPath: stringArg(args, key: "--vault"))
        }

        // Parse args for the YouTube-only --extract flow.
        let url = stringArg(args, key: "--extract") ?? ""
        let count = intArg(args, key: "--count") ?? 100
        let outArg = stringArg(args, key: "--out")
        let mode = stringArg(args, key: "--mode") ?? "production"
        let maxEdge = intArg(args, key: "--max-edge") ?? 1920

        guard let videoID = extractVideoID(url) else {
            FileHandle.standardError.write("error: invalid YouTube URL: \(url)\n".data(using: .utf8)!)
            exit(2)
        }

        // Output dir: caller-supplied, else NSTemporaryDirectory (always writable in sandbox).
        let outDir: URL
        if let outArg {
            outDir = URL(fileURLWithPath: outArg, isDirectory: true)
        } else {
            outDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("youty-debug", isDirectory: true)
                .appendingPathComponent(videoID, isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        // Clear any prior run.
        if let existing = try? FileManager.default.contentsOfDirectory(at: outDir, includingPropertiesForKeys: nil) {
            for f in existing where f.pathExtension == "jpg" {
                try? FileManager.default.removeItem(at: f)
            }
        }

        // Run synchronously via DispatchSemaphore — Task.detached + wait.
        let sem = DispatchSemaphore(value: 0)
        let box = ExitBox()
        let kickoff = Date()

        Task.detached {
            defer { sem.signal() }
            do {
                let code = try await runExtraction(
                    videoID: videoID,
                    requestedCount: count,
                    outDir: outDir,
                    mode: mode,
                    maxEdge: Int32(maxEdge),
                    kickoff: kickoff
                )
                box.code = code
            } catch {
                print("EXTRACTION_ERROR=\(error.localizedDescription)")
                box.code = 3
            }
        }
        sem.wait()
        exit(box.code)
    }

    // MARK: - Extraction orchestration

    private static func runExtraction(
        videoID: String,
        requestedCount: Int,
        outDir: URL,
        mode: String,
        maxEdge: Int32,
        kickoff: Date
    ) async throws -> Int32 {

        print("MODE=\(mode)")
        print("VIDEO_ID=\(videoID)")

        // Stage 1: formats.
        let formatsStart = Date()
        let visitor = try await StreamFetcher.getVisitorData()
        let formatList = try await StreamFetcher.fetchFormats(videoID: videoID, visitorData: visitor)
        let formatsMs = Int(Date().timeIntervalSince(formatsStart) * 1000)
        let duration = formatList.lengthSeconds
        guard duration > 0 else {
            print("ERROR=zero-duration")
            return 2
        }

        // Stage 2: stream selection.
        let stream: VideoStream
        do {
            stream = try StreamFetcher.selectFastPathStream(
                from: formatList.formats,
                progressiveCount: formatList.progressiveCount)
        } catch {
            print("ERROR=stream-selection: \(error.localizedDescription)")
            return 2
        }
        print("DURATION_S=\(String(format: "%.1f", duration))")
        print("STREAM_QUALITY=\(stream.quality)")
        print("STREAM_CODEC=\(stream.codec)")
        print("STREAM_BYTES=\(stream.contentLength)")

        // Stage 3: timestamps.
        let cap = max(1, min(1000, requestedCount))
        let timestamps = FrameExtractor.frameTimes(duration: duration,
                                                    countCap: cap,
                                                    fpsCap: FrameExtractor.defaultFpsCap)
        print("FRAMES_REQUESTED=\(timestamps.count)")

        // Stage 4: extract via selected pipeline.
        let extractStart = Date()
        let frames: [(timestamp: TimeInterval, image: NSImage)]
        do {
            switch mode {
            case "phase1":
                frames = try await PhaseIFrameExtractor.extract(
                    url: stream.url,
                    userAgent: StreamFetcher.androidVRUA,
                    timestamps: timestamps,
                    maxLongEdge: maxEdge,
                    progress: { _ in })
            case "production", "":
                frames = try await FFmpegFrameExtractor.extract(
                    url: stream.url,
                    userAgent: StreamFetcher.androidVRUA,
                    timestamps: timestamps,
                    maxLongEdge: maxEdge,
                    progress: { _ in })
            case "auto":
                // Mirrors FastFramePipeline.shouldTryPhaseI.
                let bitrate = duration > 0 ? Double(stream.contentLength) / duration : 0
                let smallShort = duration < 480 && stream.contentLength < 40_000_000
                let highBitrate = bitrate > 500_000
                let usePhaseI = !smallShort && !highBitrate
                print("AUTO_DECISION=\(usePhaseI ? "phase1" : "production")")
                if usePhaseI {
                    do {
                        frames = try await PhaseIFrameExtractor.extract(
                            url: stream.url,
                            userAgent: StreamFetcher.androidVRUA,
                            timestamps: timestamps,
                            maxLongEdge: maxEdge,
                            progress: { _ in })
                    } catch {
                        print("AUTO_FALLBACK=phase1->production: \(error.localizedDescription)")
                        frames = try await FFmpegFrameExtractor.extract(
                            url: stream.url,
                            userAgent: StreamFetcher.androidVRUA,
                            timestamps: timestamps,
                            maxLongEdge: maxEdge,
                            progress: { _ in })
                    }
                } else {
                    frames = try await FFmpegFrameExtractor.extract(
                        url: stream.url,
                        userAgent: StreamFetcher.androidVRUA,
                        timestamps: timestamps,
                        maxLongEdge: maxEdge,
                        progress: { _ in })
                }
            default:
                print("ERROR=unknown-mode: \(mode)")
                return 2
            }
        } catch {
            let extractMs = Int(Date().timeIntervalSince(extractStart) * 1000)
            print("PHASE_FORMATS_MS=\(formatsMs)")
            print("PHASE_EXTRACT_MS=\(extractMs)")
            print("EXTRACTION_ERROR=\(error.localizedDescription)")
            return 3
        }
        let extractMs = Int(Date().timeIntervalSince(extractStart) * 1000)
        print("FRAMES_RETURNED=\(frames.count)")

        // Stage 5: write JPEGs + compute SHA-256 distinct count. Parallel
        // encode via TaskGroup; sequential write (single SSD anyway).
        let writeStart = Date()
        let encoded: [(name: String, data: Data, hash: String)] =
            await withTaskGroup(of: (String, Data, String)?.self) { group in
                for frame in frames {
                    group.addTask {
                        let ms = Int(frame.timestamp * 1000)
                        let name = String(format: "%08d.jpg", ms)
                        guard let data = frame.image.jpegData(compressionQuality: 0.85) else {
                            return nil
                        }
                        let h = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
                        return (name, data, h)
                    }
                }
                var out: [(String, Data, String)] = []
                for await item in group { if let item { out.append(item) } }
                return out
            }
        var hashes: Set<String> = []
        for (name, data, hash) in encoded {
            try? data.write(to: outDir.appendingPathComponent(name))
            hashes.insert(hash)
        }
        let writeMs = Int(Date().timeIntervalSince(writeStart) * 1000)

        let totalMs = Int(Date().timeIntervalSince(kickoff) * 1000)
        print("FRAMES_DISTINCT_SHA=\(hashes.count)")
        print("PHASE_FORMATS_MS=\(formatsMs)")
        print("PHASE_EXTRACT_MS=\(extractMs)")
        print("PHASE_WRITE_MS=\(writeMs)")
        print("TOTAL_MS=\(totalMs)")
        print("OUT_DIR=\(outDir.path)")

        if frames.count < timestamps.count {
            return 1
        }
        return 0
    }

    // MARK: - Platform probes

    private static func runTikTokProbe(urlString: String) -> Never {
        guard let url = URL(string: urlString) else {
            FileHandle.standardError.write("error: invalid URL\n".data(using: .utf8)!)
            exit(2)
        }
        let fullPipeline = CommandLine.arguments.contains("--full")
        let sem = DispatchSemaphore(value: 0)
        let box = ExitBox()
        Task.detached {
            defer { sem.signal() }
            do {
                let t0 = Date()
                let r = try await TikTokExtractor.extract(url: url)
                let extractMs = Int(Date().timeIntervalSince(t0) * 1000)
                print("EXTRACT ms=\(extractMs)")
                print("video_id=\(r.metadata.videoID)")
                print("author=\(r.metadata.author)  (\(r.metadata.authorDisplayName))")
                print("description=\(r.metadata.description.prefix(160))")
                print("duration_s=\(r.metadata.duration)  res=\(r.metadata.width)x\(r.metadata.height)")
                print("stats plays=\(r.metadata.plays ?? -1) likes=\(r.metadata.likes ?? -1) comments=\(r.metadata.comments ?? -1) shares=\(r.metadata.shares ?? -1) saves=\(r.metadata.saves ?? -1)")
                print("music=\(r.metadata.musicTitle ?? "?") — \(r.metadata.musicAuthor ?? "?")")
                print("hashtags=\(r.metadata.hashtags.joined(separator: ","))")
                print("posted_at=\(r.metadata.postedAt.map(ISO8601DateFormatter().string(from:)) ?? "?")")
                print("video_cdn_url=\(r.videoCDNURL.absoluteString)")
                if let caps = r.captions {
                    print("captions count=\(caps.count) first=\"\(caps.first?.text.prefix(80) ?? "")\" timestamp=\(caps.first?.timestamp ?? "?")")
                } else {
                    print("captions=none (would fall back to SpeechTranscriber)")
                }

                if !fullPipeline {
                    box.code = 0
                    return
                }

                // Full pipeline: download → frames + transcript in parallel.
                let dlStart = Date()
                let fileURL = try await MediaDownloader.download(
                    url: r.videoCDNURL,
                    headers: r.videoDownloadHeaders,
                    progress: nil
                )
                let dlMs = Int(Date().timeIntervalSince(dlStart) * 1000)
                let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
                let size = (attrs?[.size] as? Int) ?? 0
                print("DOWNLOAD ms=\(dlMs) bytes=\(size) path=\(fileURL.lastPathComponent)")

                // Compute frame timestamps.
                let frameTimes = FrameExtractor.frameTimes(duration: r.metadata.duration)
                print("FRAMES_REQUESTED=\(frameTimes.count) over \(r.metadata.duration)s")

                async let framesTask: [(timestamp: TimeInterval, image: NSImage)] = {
                    try await LocalFrameExtractor.extract(
                        fileURL: fileURL,
                        timestamps: frameTimes,
                        maxLongEdge: 1920,
                        progress: { _ in })
                }()

                async let transcriptTask: [TranscriptSegment]? = {
                    if let caps = r.captions { return caps }
                    do {
                        return try await SpeechTranscriptionPipeline.transcribe(audioURL: fileURL)
                    } catch {
                        print("SPEECH_ERROR=\(error.localizedDescription)")
                        return nil
                    }
                }()

                let frames = try await framesTask
                let trans = await transcriptTask

                let frameMs = Int(Date().timeIntervalSince(dlStart) * 1000) - dlMs
                print("FRAMES_RETURNED=\(frames.count) frame_phase_ms=\(frameMs)")
                if let trans { print("TRANSCRIPT_SEGS=\(trans.count) first=\"\((trans.first?.text ?? "").prefix(100))\"") }

                let totalMs = Int(Date().timeIntervalSince(t0) * 1000)
                print("TOTAL_MS=\(totalMs)")

                MediaDownloader.remove(fileURL)
                box.code = 0
            } catch {
                print("ERROR=\(error.localizedDescription)")
                box.code = 3
            }
        }
        sem.wait()
        exit(box.code)
    }

    private static func runInstagramProbe(urlString: String) -> Never {
        guard let url = URL(string: urlString) else {
            FileHandle.standardError.write("error: invalid URL\n".data(using: .utf8)!)
            exit(2)
        }
        Task { @MainActor in
            let box = ExitBox()
            do {
                let signedIn = await InstagramExtractor.isSignedIn()
                print("SIGNED_IN=\(signedIn)")
                let extractor = InstagramExtractor()
                let r = try await extractor.extract(url: url)
                print("OK shortcode=\(r.metadata.shortcode) author=\(r.metadata.author)")
                print("caption_chars=\(r.metadata.caption.count)")
                print("duration_s=\(r.metadata.duration) res=\(r.metadata.width)x\(r.metadata.height)")
                print("video_cdn_url=\(r.videoCDNURL.absoluteString)")
                box.code = 0
            } catch {
                print("ERROR=\(error.localizedDescription)")
                if let e = error as? InstagramExtractorError, case .notLoggedIn = e {
                    print("HINT=expected for sandboxed test without prior in-app login")
                }
                box.code = 3
            }
            exit(box.code)
        }
        dispatchMain()
    }

    private static func runShortFormSaveProbe(urlString: String, vaultPath: String?) -> Never {
        guard let url = URL(string: urlString) else {
            FileHandle.standardError.write("error: invalid URL\n".data(using: .utf8)!)
            exit(2)
        }
        let vaultURL: URL = {
            if let p = vaultPath {
                let u = URL(fileURLWithPath: p, isDirectory: true)
                try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
                return u
            }
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("youty-vault-test", isDirectory: true)
            try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            return tmp
        }()

        // Use dispatchMain() to pump the main runloop so @MainActor work can
        // dispatch. The Task exits the process when done.
        Task { @MainActor in
            let box = ExitBox()
            await box.runShortFormSave(url: url, vault: vaultURL)
            exit(box.code)
        }
        dispatchMain()
    }

    private static func runSpeechProbe(audioPath: String) -> Never {
        let url = URL(fileURLWithPath: audioPath)
        let sem = DispatchSemaphore(value: 0)
        let box = ExitBox()
        Task.detached {
            defer { sem.signal() }
            do {
                let t0 = Date()
                let segs = try await SpeechTranscriptionPipeline.transcribe(audioURL: url)
                let dt = Int(Date().timeIntervalSince(t0) * 1000)
                print("OK ms=\(dt) segments=\(segs.count)")
                for s in segs.prefix(8) {
                    print("[\(s.timestamp)] \(s.text)")
                }
                box.code = 0
            } catch {
                print("ERROR=\(error.localizedDescription)")
                box.code = 3
            }
        }
        sem.wait()
        exit(box.code)
    }

    // MARK: - Box for cross-Task mutable state

    private final class ExitBox: @unchecked Sendable {
        var code: Int32 = 3

        @MainActor
        func runShortFormSave(url: URL, vault: URL) async {
            do {
                let started = Date()
                let vm = VaultManager()
                vm.vaultURL = vault
                let pipeline = ShortFormPipeline(vault: vm)
                let preview = try await pipeline.preview(url: url)
                print("PREVIEW author=\(preview.author) duration=\(preview.duration)")
                let stageHandler: @Sendable (FrameStage) -> Void = { stage in
                    switch stage {
                    case .loading: print("STAGE=loading")
                    case .downloading(let p): print("STAGE=downloading \(Int(p * 100))%")
                    case .extracting(let p):  print("STAGE=extracting \(Int(p * 100))%")
                    case .writing: print("STAGE=writing")
                    }
                }
                let result = try await pipeline.save(preview: preview, stage: stageHandler)
                let total = Int(Date().timeIntervalSince(started) * 1000)
                print("SAVE folder=\(result.folder.path) frames=\(result.framesWritten) transcript=\(result.transcriptSegments) total_ms=\(total)")
                let mdPath = result.folder.appendingPathComponent("video.md")
                if let txt = try? String(contentsOf: mdPath, encoding: .utf8) {
                    print("VIDEOMD chars=\(txt.count) head:")
                    print(String(txt.prefix(500)))
                }
                let jpegs = (try? FileManager.default.contentsOfDirectory(atPath: result.folder.path))?
                    .filter { $0.hasSuffix(".jpg") }.count ?? 0
                print("JPEGS_ON_DISK=\(jpegs)")
                code = 0
            } catch {
                print("ERROR=\(error.localizedDescription)")
                code = 3
            }
        }
    }

    // MARK: - Arg parsing

    private static func stringArg(_ args: [String], key: String) -> String? {
        guard let idx = args.firstIndex(of: key), idx + 1 < args.count else { return nil }
        return args[idx + 1]
    }

    private static func intArg(_ args: [String], key: String) -> Int? {
        guard let s = stringArg(args, key: key) else { return nil }
        return Int(s)
    }

    private static func extractVideoID(_ urlString: String) -> String? {
        // Reuses the canonical extractor in TranscriptFetcher.
        return TranscriptFetcher.extractVideoID(from: urlString)
    }
}
