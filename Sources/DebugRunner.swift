import Foundation
import AppKit
import CryptoKit
import CoreML
import CoreVideo

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
            || CommandLine.arguments.contains("--reindex")
            || CommandLine.arguments.contains("--index-frames")
            || CommandLine.arguments.contains("--phase-l-probe")
            || CommandLine.arguments.contains("--phase-l-e2e-check")
            || CommandLine.arguments.contains("--hardness-probe")
            || CommandLine.arguments.contains("--bench-indexer")
            || CommandLine.arguments.contains("--siglip-probe")
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
        if let vaultPath = stringArg(args, key: "--reindex") {
            runReindexProbe(vaultPath: vaultPath)
        }
        if let vaultPath = stringArg(args, key: "--index-frames") {
            runIndexFramesProbe(vaultPath: vaultPath)
        }
        if args.contains("--phase-l-probe") {
            runPhaseLProbe()
        }
        if args.contains("--phase-l-e2e-check") {
            runPhaseLE2ECheck()
        }
        if args.contains("--hardness-probe") {
            runHardnessProbe()
        }
        if let nStr = stringArg(args, key: "--bench-indexer") {
            runBenchIndexer(count: Int(nStr) ?? 1000)
        }
        if args.contains("--siglip-probe") {
            runSigLIPProbe()
        }

        // Parse args for the YouTube-only --extract flow.
        let url = stringArg(args, key: "--extract") ?? ""
        let count = intArg(args, key: "--count") ?? 100
        let outArg = stringArg(args, key: "--out")
        let mode = stringArg(args, key: "--mode") ?? "production"
        // --resolution overrides the user setting for headless testing. Falls
        // back to the user's saved setting (or 1080 if never set).
        let resolution: Int = {
            if let r = intArg(args, key: "--resolution") { return r }
            let stored = UserDefaults.standard.integer(forKey: "targetResolution")
            return stored == 0 ? 1080 : stored
        }()
        // --max-edge caps the decoded frame size. If omitted, derive from the
        // chosen resolution so the JPEG actually matches the picked source.
        let maxEdge = intArg(args, key: "--max-edge") ?? {
            switch resolution {
            case 720:  return 1280
            case 1080: return 1920
            case 1440: return 2560
            case 2160: return 3840
            default:   return 1920
            }
        }()

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
                    targetResolution: resolution,
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
        targetResolution: Int,
        kickoff: Date
    ) async throws -> Int32 {

        print("MODE=\(mode)")
        print("VIDEO_ID=\(videoID)")
        print("TARGET_RESOLUTION=\(targetResolution)p")

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
                progressiveCount: formatList.progressiveCount,
                targetResolution: targetResolution)
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

    // Headless Phase B smoke test. Walks every video.md under the given
    // vault path, embeds each via Gemini, writes into the SQLite index at
    // ~/Library/Application Support/Youty/index.db. Exit codes:
    //   0 — all bundles indexed cleanly
    //   1 — partial: some bundles failed (e.g. transient network)
    //   2 — setup error (missing key, unreadable vault)
    //   3 — fatal (DB open, embedder ctor)
    private static func runReindexProbe(vaultPath: String) -> Never {
        // Resolve the path. If the user passed the same folder they previously
        // selected in the Mac app's UI, use the stored security-scoped
        // bookmark so the sandbox grants access. Otherwise the bare path is
        // only readable when it's inside the app's container (e.g. ~/Library/
        // Containers/dev.leget.youty/Data/tmp/...).
        let bareURL = URL(fileURLWithPath: vaultPath, isDirectory: true).standardizedFileURL
        var vaultURL = bareURL
        var bookmarkedURL: URL?
        if let data = UserDefaults.standard.data(forKey: "vaultBookmark") {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data,
                                  options: .withSecurityScope,
                                  relativeTo: nil,
                                  bookmarkDataIsStale: &stale) {
                bookmarkedURL = url.standardizedFileURL
                if url.standardizedFileURL.path == bareURL.path {
                    vaultURL = url
                }
            }
        }
        let scoped = vaultURL.startAccessingSecurityScopedResource()
        defer { if scoped { vaultURL.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.fileExists(atPath: vaultURL.path) else {
            FileHandle.standardError.write("error: vault path does not exist or is sandbox-blocked: \(vaultPath)\n".data(using: .utf8)!)
            if let b = bookmarkedURL, b.path != bareURL.path {
                FileHandle.standardError.write(
                    "  hint: app currently has a security-scoped bookmark for \(b.path) — pass that path instead, or open the app UI once to re-bookmark.\n".data(using: .utf8)!)
            }
            exit(2)
        }
        let sem = DispatchSemaphore(value: 0)
        let box = ExitBox()
        Task.detached { [vaultURL] in
            defer { sem.signal() }
            do {
                let dbPath = (try? IndexStore.databasePath()) ?? "?"
                print("VAULT_ROOT=\(vaultURL.path)")
                print("INDEX_DB=\(dbPath)")
                print("SCOPED_RESOURCE=\(scoped)")
                let summary = try await Indexer.reindexVault(vaultRoot: vaultURL) { line in
                    print(line)
                }
                print("VIDEOS_INDEXED=\(summary.videosIndexed)")
                print("CHUNKS_WRITTEN=\(summary.chunksWritten)")
                print("VIDEOS_DELETED=\(summary.videosDeleted)")
                print("FAILURES=\(summary.failures.count)")
                for f in summary.failures {
                    print("FAIL_DETAIL folder=\(f.folder) error=\(f.error)")
                }
                print("TOTAL_MS=\(summary.totalMs)")
                box.code = summary.failures.isEmpty ? 0 : 1
            } catch let e as IndexerError {
                print("SETUP_ERROR=\(e.localizedDescription)")
                box.code = 2
            } catch {
                print("FATAL=\(error.localizedDescription)")
                box.code = 3
            }
        }
        sem.wait()
        exit(box.code)
    }

    // Headless frame indexer. Walks every bundle, runs pHash + SigLIP-Base,
    // writes to the `frames` table. Bundles using the legacy 4-digit-seconds
    // JPEG names are silently skipped (FRAMES_KEPT=0 each).
    private static func runIndexFramesProbe(vaultPath: String) -> Never {
        let bareURL = URL(fileURLWithPath: vaultPath, isDirectory: true).standardizedFileURL
        var vaultURL = bareURL
        if let data = UserDefaults.standard.data(forKey: "vaultBookmark") {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data,
                                  options: .withSecurityScope,
                                  relativeTo: nil,
                                  bookmarkDataIsStale: &stale),
               url.standardizedFileURL.path == bareURL.path {
                vaultURL = url
            }
        }
        let scoped = vaultURL.startAccessingSecurityScopedResource()
        defer { if scoped { vaultURL.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.fileExists(atPath: vaultURL.path) else {
            FileHandle.standardError.write("error: vault path does not exist or is sandbox-blocked: \(vaultPath)\n".data(using: .utf8)!)
            exit(2)
        }
        let sem = DispatchSemaphore(value: 0)
        let box = ExitBox()
        Task.detached { [vaultURL] in
            defer { sem.signal() }
            do {
                let dbPath = (try? IndexStore.databasePath()) ?? "?"
                let modelPath = (try? SigLIPLoader.bundledModelURL().path) ?? "?"
                print("VAULT_ROOT=\(vaultURL.path)")
                print("INDEX_DB=\(dbPath)")
                print("MODEL_PATH=\(modelPath)")
                print("SCOPED_RESOURCE=\(scoped)")
                let summary = try await Indexer.reindexFrames(vaultRoot: vaultURL) { line in
                    print(line)
                }
                print("VIDEOS_PROCESSED=\(summary.videosProcessed)")
                print("VIDEOS_SKIPPED=\(summary.videosSkipped)")
                print("FRAMES_KEPT=\(summary.framesKept)")
                print("FRAMES_DROPPED_DEDUPE=\(summary.framesDroppedDedupe)")
                print("FAILURES=\(summary.failures.count)")
                for f in summary.failures {
                    print("FAIL_DETAIL folder=\(f.folder) error=\(f.error)")
                }
                print("TOTAL_MS=\(summary.totalMs)")
                box.code = summary.failures.isEmpty ? 0 : 1
            } catch let e as IndexerError {
                print("SETUP_ERROR=\(e.localizedDescription)")
                box.code = 2
            } catch {
                print("FATAL=\(error.localizedDescription)")
                box.code = 3
            }
        }
        sem.wait()
        exit(box.code)
    }

    /// Headless probe that exercises every Phase L surface that can be
    /// driven without a system UI interaction:
    ///   • IngestionFunnel ingest + queue serialization
    ///   • VaultLocalSearch keyword search
    /// Skipped: Share Sheet activation (system UI), Services menu
    /// (system UI), menu bar popover click (system UI). Those require
    /// driving the system UI from outside the app.
    private static func runPhaseLProbe() -> Never {
        // We are on the main thread (called from AppMain.main → DebugRunner.run).
        // Use MainActor.assumeIsolated to call MainActor-isolated APIs
        // synchronously — Task-based dispatch would deadlock because the
        // MainActor executor is the main thread, and we never return to
        // the run loop.
        var failures: [String] = []

        MainActor.assumeIsolated {
            // 1. Ingestion funnel — verify enqueue + serialization.
            let funnel = IngestionFunnel.shared
            funnel.ingest(urlString: "https://www.youtube.com/watch?v=test1", source: "probe")
            funnel.ingest(urlString: "https://www.youtube.com/watch?v=test2", source: "probe")
            if funnel.inboxURL?.absoluteString != "https://www.youtube.com/watch?v=test1" {
                failures.append("funnel: inbox after 2 ingests is not test1 (was \(funnel.inboxURL?.absoluteString ?? "nil"))")
            }
            if !funnel.hasWork {
                failures.append("funnel: hasWork should be true after ingest")
            }
            // Drain first → second should become inbox.
            funnel.didFinishSave()
            if funnel.inboxURL?.absoluteString != "https://www.youtube.com/watch?v=test2" {
                failures.append("funnel: after didFinishSave, inbox is not test2 (was \(funnel.inboxURL?.absoluteString ?? "nil"))")
            }
            funnel.didFinishSave()
            if funnel.hasWork {
                failures.append("funnel: hasWork should be false after final didFinishSave")
            }
            // Idempotence: re-enqueueing while active should be a no-op for
            // duplicates already queued.
            funnel.ingest(urlString: "https://www.youtube.com/watch?v=test3", source: "probe")
            funnel.ingest(urlString: "https://www.youtube.com/watch?v=test3", source: "probe")
            if funnel.inboxURL?.absoluteString != "https://www.youtube.com/watch?v=test3" {
                failures.append("funnel: third URL not dispatched")
            }
            funnel.didFinishSave()

            // 2. URL classifier — used by AppIntents, menu bar, and the
            // share-extension copy.
            let classifierCases: [(String, Bool)] = [
                ("https://www.youtube.com/watch?v=abc", true),
                ("https://youtu.be/abc",                true),
                ("https://www.tiktok.com/@user/video/123", true),
                ("https://vm.tiktok.com/abc",           true),
                ("https://www.instagram.com/reel/abc",  true),
                ("https://www.instagram.com/p/abc",     true),
                ("https://www.google.com/search?q=hi",  false),
                ("not-a-url",                            false),
            ]
            for (input, expected) in classifierCases {
                let actual = YoutyShareURLClassifier.isSupported(input)
                if actual != expected {
                    failures.append("classifier(\"\(input)\"): expected \(expected), got \(actual)")
                }
            }

            // 3. VaultLocalSearch — empty-query short-circuit returns empty.
            let results = VaultLocalSearch.search(query: "", limit: 5)
            if !results.isEmpty {
                failures.append("VaultLocalSearch.search(\"\"): expected empty, got \(results.count)")
            }
        }

        if failures.isEmpty {
            print("PHASE_L_PROBE OK")
            exit(0)
        } else {
            print("PHASE_L_PROBE FAIL")
            for f in failures { print("  - \(f)") }
            exit(1)
        }
    }

    /// Invoke each AppIntent's `perform()` directly to verify it lands in
    /// the funnel + returns sensible result values. Doesn't rely on the
    /// Shortcuts.app GUI or `shortcuts` CLI.
    /// Read the sentinel UserDefaults entry that the running app writes
    /// every time IngestionFunnel.ingest() fires. Lets a CI script verify
    /// the URL-scheme / Services / Share-Extension surfaces actually
    /// reached the funnel after launching the live app + dispatching an
    /// event.
    private static func runPhaseLE2ECheck() -> Never {
        let args = CommandLine.arguments
        let expectedURL = stringArg(args, key: "--expect-url")
        let expectedSource = stringArg(args, key: "--expect-source")
        guard let raw = UserDefaults.standard.dictionary(forKey: "phaseLProbe.lastIngest") else {
            print("PHASE_L_E2E_FAIL no sentinel")
            exit(1)
        }
        let url = raw["url"] as? String ?? ""
        let source = raw["source"] as? String ?? ""
        if let exp = expectedURL, exp != url {
            print("PHASE_L_E2E_FAIL url=\(url) want=\(exp)")
            exit(1)
        }
        if let exp = expectedSource, exp != source {
            print("PHASE_L_E2E_FAIL source=\(source) want=\(exp)")
            exit(1)
        }
        print("PHASE_L_E2E_OK url=\(url) source=\(source)")
        exit(0)
    }

    /// Q.6 — drive every weird vault state we can simulate headlessly and
    /// confirm nothing crashes. Each case sets up a synthetic temp vault,
    /// triggers the read/write path, and asserts the outcome.
    ///
    /// Cases that need physical hardware (yanked external drive, disk full,
    /// network dropped mid-fetch) are documented but not covered here.
    private static func runHardnessProbe() -> Never {
        let failures = HardnessFailureBox()
        let fm = FileManager.default
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("youty-hardness-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpRoot) }

        MainActor.assumeIsolated {
            // ---- Case 1: completely empty vault (zero bundles) ----
            let empty = tmpRoot.appendingPathComponent("empty", isDirectory: true)
            try? fm.createDirectory(at: empty, withIntermediateDirectories: true)
            VaultManager.writeManifest(in: empty)
            if let data = try? Data(contentsOf: empty.appendingPathComponent("manifest.json")),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [Any] {
                if !arr.isEmpty {
                    failures.add("empty vault: manifest had \(arr.count) entries, expected 0")
                }
            } else {
                failures.add("empty vault: manifest.json missing or invalid after writeManifest")
            }

            // ---- Case 2: vault path is a regular file, not a directory ----
            let asFile = tmpRoot.appendingPathComponent("not-a-folder")
            try? Data("nope".utf8).write(to: asFile)
            // Should not crash. Should produce no manifest.json next to the
            // file (write to "manifest.json" path inside a file-as-folder
            // either no-ops or fails silently via `try?`).
            VaultManager.writeManifest(in: asFile)
            // No assertion — survival is the test.

            // ---- Case 3: vault directory exists but contains garbage manifest.json ----
            let badManifestVault = tmpRoot.appendingPathComponent("bad-manifest", isDirectory: true)
            try? fm.createDirectory(at: badManifestVault, withIntermediateDirectories: true)
            let badManifestPath = badManifestVault.appendingPathComponent("manifest.json")
            for garbage in [
                "",                                          // empty file
                "not json at all",                           // raw text
                "{",                                         // truncated JSON
                "{\"foo\":\"bar\"}",                         // valid JSON, wrong shape
                "[1, 2, 3]",                                 // array of wrong items
                String(repeating: "x", count: 10_000),      // huge garbage
                "\u{FEFF}[]"                                 // BOM-prefixed empty array
            ] {
                try? Data(garbage.utf8).write(to: badManifestPath)
                // Writers should overwrite the garbage with a valid empty
                // array (no bundles in this vault).
                VaultManager.writeManifest(in: badManifestVault)
                let after = (try? Data(contentsOf: badManifestPath)) ?? Data()
                if (try? JSONSerialization.jsonObject(with: after) as? [Any]) == nil {
                    failures.add("garbage-manifest case \"\(garbage.prefix(20))…\": writeManifest didn't repair the file")
                }
            }

            // ---- Case 4: bundles with corrupt or partial video.md ----
            let corruptVault = tmpRoot.appendingPathComponent("corrupt", isDirectory: true)
            let youtubeDir = corruptVault.appendingPathComponent("youtube", isDirectory: true)
            try? fm.createDirectory(at: youtubeDir, withIntermediateDirectories: true)
            let corruptCases: [(name: String, body: String)] = [
                ("no-frontmatter", "Just some text with no YAML markers at all."),
                ("partial-frontmatter", "---\ntitle: Test\n"),                  // missing closing ---
                ("frontmatter-only-no-id", "---\ntitle: Test\nplatform: youtube\n---\nBody"),
                ("garbage-frontmatter", "---\n!@#$%^&*()_+\nnot=valid:yaml\n---\nBody"),
                ("just-dashes", "---\n---"),
                ("empty-file", ""),
                ("binary-bytes", String(decoding: Data([0xFF, 0xFE, 0x00, 0x00, 0x7F]), as: UTF8.self)),
            ]
            for c in corruptCases {
                let folder = youtubeDir.appendingPathComponent(c.name, isDirectory: true)
                try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
                try? Data(c.body.utf8).write(to: folder.appendingPathComponent("video.md"))
            }
            // writeManifest should walk all of them without crashing and
            // emit an empty array (or whichever ones happen to parse — none
            // should, since none have a valid video_id).
            VaultManager.writeManifest(in: corruptVault)
            let corruptManifestPath = corruptVault.appendingPathComponent("manifest.json")
            if let data = try? Data(contentsOf: corruptManifestPath),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [Any] {
                if !arr.isEmpty {
                    failures.add("corrupt-bundles: writeManifest produced \(arr.count) entries from garbage video.md")
                }
            } else {
                failures.add("corrupt-bundles: no valid manifest after writeManifest")
            }

            // ---- Case 5: read-only vault directory ----
            let readOnly = tmpRoot.appendingPathComponent("readonly", isDirectory: true)
            try? fm.createDirectory(at: readOnly, withIntermediateDirectories: true)
            try? fm.setAttributes([.posixPermissions: NSNumber(value: 0o555)],
                                  ofItemAtPath: readOnly.path)
            // writeManifest internally uses `try?` so it should just fail
            // silently — no crash, no exception, no manifest.
            VaultManager.writeManifest(in: readOnly)
            // Restore perms so the temp-cleanup at end of probe works.
            try? fm.setAttributes([.posixPermissions: NSNumber(value: 0o755)],
                                  ofItemAtPath: readOnly.path)

            // ---- Case 6: vault path doesn't exist at all ----
            let ghost = tmpRoot.appendingPathComponent("does-not-exist", isDirectory: true)
            VaultManager.writeManifest(in: ghost)
            // No crash. No file produced. The next writeManifest after
            // someone creates the directory should work — let's verify.
            try? fm.createDirectory(at: ghost, withIntermediateDirectories: true)
            VaultManager.writeManifest(in: ghost)
            if !fm.fileExists(atPath: ghost.appendingPathComponent("manifest.json").path) {
                failures.add("ghost-vault: writeManifest after directory creation didn't produce a manifest")
            }

            // ---- Case 7: vault with mixed valid + corrupt bundles ----
            let mixed = tmpRoot.appendingPathComponent("mixed", isDirectory: true)
            let mixedYT = mixed.appendingPathComponent("youtube", isDirectory: true)
            try? fm.createDirectory(at: mixedYT, withIntermediateDirectories: true)
            // One valid bundle
            let validFolder = mixedYT.appendingPathComponent("Valid Channel - Valid Title", isDirectory: true)
            try? fm.createDirectory(at: validFolder, withIntermediateDirectories: true)
            try? Data("""
                ---
                video_id: abc123
                title: Valid Title
                channel: Valid Channel
                platform: youtube
                url: https://www.youtube.com/watch?v=abc123
                date_saved: 2026-05-14T12:00:00Z
                ---
                Body text.
                """.utf8).write(to: validFolder.appendingPathComponent("video.md"))
            // One corrupt sibling
            let badFolder = mixedYT.appendingPathComponent("Bad Bundle", isDirectory: true)
            try? fm.createDirectory(at: badFolder, withIntermediateDirectories: true)
            try? Data("garbage".utf8).write(to: badFolder.appendingPathComponent("video.md"))
            VaultManager.writeManifest(in: mixed)
            let mixedManifest = mixed.appendingPathComponent("manifest.json")
            if let data = try? Data(contentsOf: mixedManifest),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                if arr.count != 1 {
                    failures.add("mixed vault: expected 1 entry, got \(arr.count)")
                } else if (arr[0]["video_id"] as? String) != "abc123" {
                    failures.add("mixed vault: surviving entry's video_id is \(arr[0]["video_id"] ?? "nil"), expected abc123")
                }
            } else {
                failures.add("mixed vault: manifest unreadable after writeManifest")
            }
        }

        let collected = failures.all
        if collected.isEmpty {
            print("HARDNESS_PROBE OK")
            exit(0)
        } else {
            print("HARDNESS_PROBE FAIL")
            for f in collected { print("  - \(f)") }
            exit(1)
        }
    }

    /// Q.8 — synthetic-vault throughput benchmark. Generates `count`
    /// realistic-looking bundles in a tmp vault, then times the parts of
    /// the indexer pipeline that don't need a network round-trip:
    ///   1. `VaultManager.writeManifest` (file walk + frontmatter parse).
    ///   2. `VaultLocalSearch.search` against the resulting manifest.
    ///   3. Re-walking the same vault a second time (warm cache).
    /// Reports throughput so a Phase B→M regression on these paths shows
    /// up as a clear "X seconds for N videos" number.
    private static func runBenchIndexer(count: Int) -> Never {
        let fm = FileManager.default
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("youty-bench-\(UUID().uuidString)", isDirectory: true)
        let youtube = tmp.appendingPathComponent("youtube", isDirectory: true)
        try? fm.createDirectory(at: youtube, withIntermediateDirectories: true)

        print("==> Generating \(count) synthetic bundles in \(tmp.path)")
        let genStart = Date()
        for i in 0..<count {
            let folder = youtube.appendingPathComponent("Channel \(i % 100) - Title \(i)")
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            // ~2 KB of realistic-shaped video.md per bundle.
            let body = """
                ---
                video_id: synth\(i)
                title: "Synthetic Bench Title \(i) — the AI built a video"
                channel: "Channel \(i % 100)"
                platform: youtube
                url: https://www.youtube.com/watch?v=synth\(i)
                duration: "10:00"
                date_saved: 2026-05-14T12:00:00Z
                tags: ["benchmark", "synthetic", "youty"]
                ---
                ## Description

                Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do
                eiusmod tempor incididunt ut labore et dolore magna aliqua.

                ## Transcript

                [0:00] Hello, this is synthetic transcript line 1 of \(i).
                [0:05] And this is the second line of the synthetic transcript.
                [0:11] Line three — talking about benchmarks and indexers.
                [0:18] Fourth line, longer this time, to bulk up the chunk size.
                [0:26] Line five wraps things up, with a final long thought.
                """
            try? Data(body.utf8).write(to: folder.appendingPathComponent("video.md"))
        }
        let genMs = Int(Date().timeIntervalSince(genStart) * 1000)
        print("    generation: \(genMs) ms (\(genMs / max(count, 1)) µs/bundle)")

        let failures = HardnessFailureBox()
        MainActor.assumeIsolated {
            // 1. Cold manifest build.
            let coldStart = Date()
            VaultManager.writeManifest(in: tmp)
            let coldMs = Int(Date().timeIntervalSince(coldStart) * 1000)
            let manifestData = (try? Data(contentsOf: tmp.appendingPathComponent("manifest.json"))) ?? Data()
            let manifestKB = manifestData.count / 1024
            let arrCount = ((try? JSONSerialization.jsonObject(with: manifestData)) as? [Any])?.count ?? 0
            print("    cold writeManifest: \(coldMs) ms (\(coldMs * 1000 / max(count, 1)) µs/bundle) — manifest=\(manifestKB) KB, \(arrCount) entries")
            if arrCount != count {
                failures.add("cold writeManifest: produced \(arrCount) entries, expected \(count)")
            }

            // 2. Warm rebuild (manifest already exists).
            let warmStart = Date()
            VaultManager.writeManifest(in: tmp)
            let warmMs = Int(Date().timeIntervalSince(warmStart) * 1000)
            print("    warm writeManifest: \(warmMs) ms")

            // 3. Keyword search against the manifest.
            //
            // VaultLocalSearch.search reads the manifest via vaultRootURL()
            // which only resolves the UserDefaults bookmark — useless for
            // this tmp vault. Re-implement the same scoring inline so we
            // benchmark the pure search math against our synthetic data.
            let searchStart = Date()
            let entries = (try? JSONDecoder().decode(
                [VaultManager.ManifestEntry].self,
                from: manifestData
            )) ?? []
            let needle = "synthetic"
            let hits = entries.filter { entry in
                let hay = ([entry.title, entry.channel] + entry.tags).joined(separator: " ").lowercased()
                return hay.contains(needle)
            }.prefix(10)
            let searchMs = Int(Date().timeIntervalSince(searchStart) * 1000)
            print("    keyword search over \(entries.count): \(searchMs) ms (\(hits.count) top hits)")
            if hits.isEmpty {
                failures.add("keyword search returned zero hits when every entry contains 'synthetic'")
            }
        }

        try? fm.removeItem(at: tmp)

        let issues = failures.all
        if issues.isEmpty {
            print("BENCH_INDEXER OK")
            exit(0)
        } else {
            print("BENCH_INDEXER FAIL")
            for s in issues { print("  - \(s)") }
            exit(1)
        }
    }

    private final class HardnessFailureBox: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ s: String) { lock.lock(); defer { lock.unlock() }; items.append(s) }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
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
                let pipeline = ShortFormPipeline(vault: vm, settings: SettingsStore())
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

    // SigLIP-probe — proves the bundled image encoder (Vendor/siglip/) loads
    // and runs an actual prediction on the ANE. Creates a synthetic 224×224
    // RGB pixel buffer (deterministic gradient), runs it through
    // SigLIPLoader → CoreML, validates the output is a 768-dim
    // L2-normalised vector.
    //
    // Catches regressions that build + accessibility audit wouldn't:
    //   - .mlmodelc resource path resolution under Bundle.main
    //   - CoreML model input/output schema mismatches after a conversion change
    //   - Unexpected dtype on the output multiarray
    private static func runSigLIPProbe() -> Never {
        let sem = DispatchSemaphore(value: 0)
        let box = ExitBox()
        Task.detached {
            defer { sem.signal() }
            do {
                let url = try SigLIPLoader.bundledModelURL()
                print("MODEL_PATH=\(url.path)")
                print("MODEL_EXT=\(url.pathExtension)")
                let started = Date()
                let encoder = try await SigLIPLoader.shared.imageEncoder()
                let loadMs = Int(Date().timeIntervalSince(started) * 1000)
                print("MODEL_LOAD_MS=\(loadMs)")

                // Build a synthetic 224×224 ARGB pixel buffer with a vertical
                // gradient so we can prove the model executes on non-trivial
                // input (all-zeros input can produce NaN-ish embeddings on
                // some quantized models).
                let size = siglipImageInputSize
                let attrs: [CFString: Any] = [
                    kCVPixelBufferIOSurfacePropertiesKey: [:],
                ]
                var buffer: CVPixelBuffer?
                guard CVPixelBufferCreate(nil, size, size,
                                           kCVPixelFormatType_32ARGB,
                                           attrs as CFDictionary, &buffer) == kCVReturnSuccess,
                      let buf = buffer else {
                    print("ERROR=cannot_create_pixel_buffer")
                    box.code = 2
                    return
                }
                CVPixelBufferLockBaseAddress(buf, [])
                let base = CVPixelBufferGetBaseAddress(buf)!
                let stride = CVPixelBufferGetBytesPerRow(buf)
                for y in 0..<size {
                    let row = base.advanced(by: y * stride)
                    for x in 0..<size {
                        let pixel = row.advanced(by: x * 4)
                            .assumingMemoryBound(to: UInt8.self)
                        pixel[0] = 255                           // A
                        pixel[1] = UInt8(min(255, y))            // R: vertical gradient
                        pixel[2] = UInt8(min(255, x))            // G: horizontal gradient
                        pixel[3] = UInt8((x ^ y) & 0xFF)         // B: xor texture
                    }
                }
                CVPixelBufferUnlockBaseAddress(buf, [])

                let input = try MLDictionaryFeatureProvider(dictionary: [
                    "image": MLFeatureValue(pixelBuffer: buf),
                ])
                let inferStart = Date()
                let prediction = try await encoder.model.prediction(from: input)
                let inferMs = Int(Date().timeIntervalSince(inferStart) * 1000)
                print("INFER_MS=\(inferMs)")

                guard let arr = prediction.featureValue(for: "embedding")?.multiArrayValue else {
                    print("ERROR=missing_embedding_feature")
                    box.code = 3
                    return
                }
                guard arr.count == siglipEmbeddingDim else {
                    print("ERROR=unexpected_dim got=\(arr.count) expected=\(siglipEmbeddingDim)")
                    box.code = 3
                    return
                }
                print("EMBED_DIM=\(arr.count)")
                print("EMBED_DTYPE=\(arr.dataType.rawValue)")

                // Spot-check: read first 4 values + verify the vector has
                // non-trivial magnitude AND no NaN/Inf. (The Swift FrameEmbedder
                // L2-normalises in postprocess, but the bundled wrapper already
                // normalises inside the graph — verify both invariants hold.)
                var sumSq: Double = 0
                var anyNonFinite = false
                for i in 0..<arr.count {
                    let v: Float
                    switch arr.dataType {
                    case .float16:
                        let raw = arr.dataPointer.advanced(by: i * 2).load(as: UInt16.self)
                        v = Float(Float16(bitPattern: raw))
                    case .float32:
                        v = arr.dataPointer.advanced(by: i * 4).load(as: Float.self)
                    default:
                        v = arr[i].floatValue
                    }
                    if !v.isFinite { anyNonFinite = true }
                    sumSq += Double(v) * Double(v)
                }
                let norm = sqrt(sumSq)
                print("EMBED_NORM=\(String(format: "%.4f", norm))")
                if anyNonFinite {
                    print("ERROR=non_finite_value_in_embedding")
                    box.code = 3
                    return
                }
                // Conversion wrapper normalises in-graph → norm should be ~1.0.
                // Accept [0.9, 1.1] window to absorb fp16 rounding.
                guard norm > 0.9 && norm < 1.1 else {
                    print("ERROR=unexpected_norm \(norm) — expected ~1.0")
                    box.code = 3
                    return
                }
                print("SIGLIP_PROBE OK")
                box.code = 0
            } catch {
                print("ERROR=\(error.localizedDescription)")
                box.code = 2
            }
        }
        sem.wait()
        exit(box.code)
    }
}
