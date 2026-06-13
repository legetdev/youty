import Foundation
import AppKit

// `youty save <url>` — saves a YouTube / Instagram / TikTok URL to the
// vault. Uses the same extractor + write pipeline the Mac app uses:
//   • YouTube: TranscriptLoader (WKWebView DOM scrape) → VaultManager.saveNote
//              → FastFramePipeline → frame indexer
//   • IG / TT: ShortFormPipeline.preview → save (downloads CDN bytes,
//              extracts frames + transcript in parallel, writes bundle)
//   • Then: Indexer.indexBundle + indexFrames for the SQLite vector index.
//
// The CLI is not sandboxed, so vault writes don't need security-scoped
// bookmarks. WKWebView still needs an NSWindow host — `CLIHostWindow`
// provides a hidden one.

enum SaveCommand {

    static func run(_ args: ParsedArgs) -> Never {
        guard let urlString = args.positionals.first, !urlString.isEmpty else {
            cliStderr("error: missing URL.\nusage: youty save <url> [options]\n")
            exit(64)
        }
        guard let platform = PlatformRouter.platform(for: urlString),
              let url = URL(string: urlString) else {
            cliStderr("error: '\(urlString)' isn't a YouTube, Instagram, or TikTok post URL.\n")
            exit(65)
        }

        guard let vaultResolution = VaultResolver.resolve(flagValue: args.value(for: "vault"),
                                                           persist: true) else {
            cliStderr(VaultResolver.noVaultMessage + "\n")
            exit(78)
        }

        let quiet = args.bool("quiet") || args.bool("q")
        let json = args.bool("json") || args.bool("j")
        let skipIndex = args.bool("no-index")
        if let raw = args.value(for: "embedder"),
           EmbeddingProvider(rawValue: raw.lowercased()) == nil {
            cliStderr("error: --embedder must be 'local' (on-device) or 'gemini' (cloud).\n")
            exit(64)
        }
        let progressLog = ProgressLog(quiet: quiet)

        progressLog.stage("Vault: \(vaultResolution.url.path) (from \(vaultResolution.source.label))")

        // Make sure the vault folder exists. CLI is unsandboxed so we can
        // create it freely. If the path is a file (or otherwise unwritable),
        // give a Q.3-style actionable error and exit cleanly.
        do {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: vaultResolution.url.path, isDirectory: &isDir),
               !isDir.boolValue {
                cliStderr("error: \(vaultResolution.url.path) is a file. Pass --vault with a folder path, or pick a different location.\n")
                exit(73)
            }
            try FileManager.default.createDirectory(
                at: vaultResolution.url, withIntermediateDirectories: true
            )
        } catch {
            cliStderr("error: couldn't create or access the vault folder. \(error.localizedDescription)\n")
            exit(73)
        }

        // Run NSApplication to keep the WKWebView's content process happy.
        // We dispatch the actual work onto a Task, then call NSApp.stop +
        // post a phantom event to unwind the run loop when finished.
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)  // no Dock icon for this run

        let result = ExitBox()
        let finalPath = StringBox()
        let finalMetadata = MetadataBox()

        Task { @MainActor in
            do {
                let saved = try await performSave(
                    url: url,
                    platform: platform,
                    vaultURL: vaultResolution.url,
                    settings: makeSettings(from: args),
                    skipIndex: skipIndex,
                    progress: progressLog
                )
                finalPath.value = saved.folder.path
                finalMetadata.title    = saved.title
                finalMetadata.videoID  = saved.videoID
                finalMetadata.platform = platform.rawValue
                finalMetadata.frameCount = saved.frameCount
                result.code = 0
            } catch {
                cliStderr("error: \(error.localizedDescription)\n")
                result.code = 1
            }
            // Drain NSApp run loop.
            NSApplication.shared.stop(nil)
            // Post a no-op event so `run()` actually returns immediately
            // rather than waiting on the next user event.
            let phantom = NSEvent.otherEvent(
                with: .applicationDefined,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 0,
                data1: 0,
                data2: 0
            )
            if let phantom = phantom {
                NSApplication.shared.postEvent(phantom, atStart: false)
            }
        }
        app.run()

        if result.code == 0 {
            // Always finalise stderr's mutating-line ('\r') progress lines
            // with a newline so the shell prompt doesn't overwrite them.
            if !quiet {
                FileHandle.standardError.write("\n".data(using: .utf8)!)
            }
            if json {
                emitJSON(path: finalPath.value, metadata: finalMetadata)
            } else if let p = finalPath.value {
                print(p)
            }
            exit(0)
        }
        exit(Int32(result.code == 0 ? 0 : result.code))
    }

    // MARK: - Driver

    private struct SavedBundle {
        let folder:     URL
        let title:      String
        let videoID:    String
        let frameCount: Int
    }

    @MainActor
    private static func performSave(url: URL,
                                    platform: Platform,
                                    vaultURL: URL,
                                    settings: SettingsStore,
                                    skipIndex: Bool,
                                    progress: ProgressLog) async throws -> SavedBundle {
        let hostWindow = CLIHostWindow.create()
        let vault = VaultManager()
        vault.vaultURL = vaultURL

        switch platform {
        case .youtube:
            return try await saveYouTube(
                url: url, vault: vault, settings: settings,
                hostWindow: hostWindow, skipIndex: skipIndex, progress: progress
            )
        case .tiktok, .instagram:
            return try await saveShortForm(
                url: url, platform: platform, vault: vault, settings: settings,
                hostWindow: hostWindow, skipIndex: skipIndex, progress: progress
            )
        }
    }

    // MARK: - YouTube path

    @MainActor
    private static func saveYouTube(url: URL,
                                    vault: VaultManager,
                                    settings: SettingsStore,
                                    hostWindow: NSWindow,
                                    skipIndex: Bool,
                                    progress: ProgressLog) async throws -> SavedBundle {
        progress.stage("Fetching YouTube transcript…")
        let loader = TranscriptLoader()
        // YouTube's default-WebKit-UA response strips captionTracks from
        // ytInitialPlayerResponse, which makes the transcript scrape miss.
        // In the GUI app the WKWebView inherits a UA from the bundle that
        // already looks Chrome-y enough; in a bare CLI binary it does not.
        // Force a Chrome UA so YouTube serves the full response.
        loader.webView.customUserAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
        loader.attachToWindow(hostWindow)
        // attachToWindow kicks off a youtube.com warm-up load that seeds
        // session cookies. In the GUI app the user takes a few seconds to
        // click Fetch, so the warm-up has time. In the CLI we call fetch
        // immediately and race the warm-up — without those cookies, YouTube
        // strips captionTracks from the video-page response. Block until
        // the warm-up settles (cap 6 s) before kicking the real fetch.
        await waitForWebViewIdle(loader.webView, timeout: 6.0)
        let result = try await loader.fetch(urlString: url.absoluteString)

        progress.stage("Writing video.md…")
        let metadata = MetadataEnricher.enrich(from: result)
        let folderURL = try vault.saveNote(result: result, metadata: metadata)

        progress.stage("Extracting frames (\(settings.frameCountCap) max, \(settings.targetResolution)p)…")
        let playerFetcher = PlayerFetcher()
        playerFetcher.attach(to: hostWindow)
        let pipeline = FastFramePipeline(
            playerFetcher: playerFetcher,
            vault: vault,
            settings: settings
        )
        let outcome = await pipeline.extract(
            videoID: result.videoID,
            folderURL: folderURL,
            stage: { stage in progress.frameStage(stage) }
        )

        let frameCount: Int
        switch outcome {
        case .success(let count, _, _):
            frameCount = count
        case .failed(let reason, _):
            throw CLIError.frameExtractionFailed(reason)
        }

        if !skipIndex {
            await runIndexer(folder: folderURL, vaultRoot: vault.vaultURL!, settings: settings, progress: progress)
        }
        return SavedBundle(folder: folderURL,
                           title: result.title,
                           videoID: result.videoID,
                           frameCount: frameCount)
    }

    // MARK: - Short-form (IG / TT) path

    @MainActor
    private static func saveShortForm(url: URL,
                                      platform: Platform,
                                      vault: VaultManager,
                                      settings: SettingsStore,
                                      hostWindow: NSWindow,
                                      skipIndex: Bool,
                                      progress: ProgressLog) async throws -> SavedBundle {
        progress.stage("Fetching \(platform.rawValue) metadata…")
        let pipeline = ShortFormPipeline(vault: vault, settings: settings)
        pipeline.attach(to: hostWindow)
        let preview: ShortFormPreview
        do {
            preview = try await pipeline.preview(url: url)
        } catch let e as InstagramExtractorError where e.errorDescription?.contains("Sign in") == true {
            throw CLIError.instagramLoginRequired
        }

        progress.stage("Saving bundle…")
        let saveResult = try await pipeline.save(preview: preview) { stage in
            progress.frameStage(stage)
        }

        let id: String
        switch platform {
        case .instagram: id = preview.instagramMetadata?.shortcode ?? "post"
        case .tiktok:    id = preview.tikTokMetadata?.videoID    ?? "post"
        case .youtube:   id = "yt"
        }

        if !skipIndex {
            await runIndexer(folder: saveResult.folder, vaultRoot: vault.vaultURL!, settings: settings, progress: progress)
        }
        return SavedBundle(folder: saveResult.folder,
                           title: preview.title,
                           videoID: id,
                           frameCount: saveResult.framesWritten)
    }

    // MARK: - Index

    @MainActor
    private static func runIndexer(folder: URL,
                                   vaultRoot: URL,
                                   settings: SettingsStore,
                                   progress: ProgressLog) async {
        let videoMd = folder.appendingPathComponent("video.md")
        let provider = settings.embeddingProvider
        progress.stage("Indexing for search… (\(provider == .local ? "on-device" : "Gemini"))")
        do {
            // Build the embedder explicitly so the CLI's --embedder / config
            // choice is honoured (the app reads the same choice from settings).
            let embedder = try Indexer.makeEmbedder(for: provider)
            try await Indexer.indexBundle(videoMdURL: videoMd, vaultRoot: vaultRoot, embedder: embedder)
        } catch {
            progress.stage("warning: text indexer skipped (\(error.localizedDescription))")
        }
        do {
            try await Indexer.indexFrames(videoMdURL: videoMd, vaultRoot: vaultRoot)
        } catch {
            progress.stage("warning: frame indexer skipped (\(error.localizedDescription))")
        }
    }

    // MARK: - Output helpers

    private static func emitJSON(path: String?, metadata: MetadataBox) {
        let payload: [String: Any] = [
            "path":     path ?? "",
            "title":    metadata.title ?? "",
            "video_id": metadata.videoID ?? "",
            "platform": metadata.platform ?? "",
            "frames":   metadata.frameCount,
        ]
        if let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]
        ),
           let str = String(data: data, encoding: .utf8) {
            print(str)
        }
    }

    @MainActor
    private static func makeSettings(from args: ParsedArgs) -> SettingsStore {
        let s = SettingsStore()
        if let n = args.intValue(for: "count")        { s.frameCountCap = n }
        if let n = args.doubleValue(for: "fps")       { s.fpsCap = n }
        if let n = args.intValue(for: "resolution")   { s.targetResolution = n }
        if let loc = args.value(for: "locale")        { s.transcriptionLocaleIdentifier = loc }
        // Embedding provider: --embedder wins and is persisted to cli-config;
        // otherwise the saved cli-config value; otherwise the on-device default.
        if let raw = args.value(for: "embedder")?.lowercased(),
           let p = EmbeddingProvider(rawValue: raw) {
            s.embeddingProvider = p
            var cfg = CLIConfigStore.read()
            cfg.embeddingProvider = p.rawValue
            CLIConfigStore.write(cfg)
        } else if let raw = CLIConfigStore.read().embeddingProvider,
                  let p = EmbeddingProvider(rawValue: raw) {
            s.embeddingProvider = p
        }
        return s
    }

    // MARK: - Boxes (Sendable-friendly refs for cross-Task mutation)

    private final class ExitBox: @unchecked Sendable {
        var code: Int = 0
    }
    private final class StringBox: @unchecked Sendable {
        var value: String?
    }
    private final class MetadataBox: @unchecked Sendable {
        var title:      String?
        var videoID:    String?
        var platform:   String?
        var frameCount: Int = 0
    }
}

// MARK: - Error type

enum CLIError: LocalizedError {
    case frameExtractionFailed(String)
    case instagramLoginRequired

    var errorDescription: String? {
        switch self {
        case .frameExtractionFailed(let reason):
            return "Couldn't extract frames: \(reason)"
        case .instagramLoginRequired:
            return """
                Instagram requires a sign-in.

                The CLI has its own web session — your Mac-app login doesn't
                carry over. Run this once:

                  youty login instagram

                A sign-in window opens; complete it normally and youty
                remembers your session for every subsequent save.
                """
        }
    }
}

// MARK: - Progress log

final class ProgressLog: @unchecked Sendable {
    private let quiet: Bool
    init(quiet: Bool) { self.quiet = quiet }

    func stage(_ text: String) {
        guard !quiet else { return }
        FileHandle.standardError.write("• \(text)\n".data(using: .utf8)!)
    }

    func frameStage(_ stage: FrameStage) {
        guard !quiet else { return }
        let label: String?
        switch stage {
        case .loading:               label = nil
        case .downloading(let p):    label = "downloading \(Int(p * 100))%"
        case .extracting(let p):     label = "extracting \(Int(p * 100))%"
        case .writing:               label = "writing frames"
        }
        if let s = label {
            // Overwrite the same line with `\r` so progress doesn't spam.
            FileHandle.standardError.write("  \(s)\r".data(using: .utf8)!)
        }
    }
}

extension VaultResolver.Source {
    var label: String {
        switch self {
        case .flag:         return "--vault"
        case .cliConfig:    return "saved CLI config"
        case .appBookmark:  return "Mac app's vault"
        }
    }
}

// stderr helper available to all commands. Named `cliStderr` to avoid
// colliding with libc's `stderr` global (which is the FILE* handle).
func cliStderr(_ message: String) {
    FileHandle.standardError.write(message.data(using: .utf8)!)
}

import WebKit

/// Poll a WKWebView's `isLoading` flag (and a small grace period) until
/// the page settles or the timeout expires. Used between attachToWindow's
/// warm-up load and the real fetch to make sure session cookies are
/// established. The grace period catches the case where isLoading drops
/// momentarily mid-redirect.
@MainActor
func waitForWebViewIdle(_ webView: WKWebView, timeout: TimeInterval) async {
    let started = Date()
    var stableForMs: Int = 0
    while Date().timeIntervalSince(started) < timeout {
        if webView.isLoading {
            stableForMs = 0
        } else {
            stableForMs += 100
            if stableForMs >= 500 { return }   // 500 ms stable → assume done
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
}
