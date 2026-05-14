import Foundation
import AppKit
import AVFoundation

// End-to-end pipeline for Instagram Reels + TikTok videos. Mirrors the
// shape of YouTube's TranscriptLoader → MetadataEnricher → VaultManager →
// FastFramePipeline chain, but for short-form progressive-MP4 content.
//
//   URL paste
//      │
//      ▼
//   ShortFormPipeline.preview(url:)
//      │   → InstagramExtractor / TikTokExtractor
//      │   → ShortFormPreview {metadata, captions?, videoURL, headers}
//      ▼
//   UI shows the title + caption + (captions when present) immediately.
//
//   "Save to Vault" click:
//      │
//      ▼
//   ShortFormPipeline.save(preview:, folder:)
//      │   1. Write video.md (frontmatter + caption + transcript-or-placeholder)
//      │   2. Download CDN video → temp file
//      │   3. In parallel: LocalFrameExtractor (frames) + SpeechTranscriber (ASR)
//      │   4. Re-write video.md with the real transcript
//      │   5. Write JPEGs into the bundle folder
//      ▼
//   Done.

enum ShortFormPipelineError: LocalizedError {
    case noVault
    case noVideoTrack
    case downloadFailed(Error)
    case framesFailed(Error)
    case speechFailed(Error)
    case writeFailed(Error)
    var errorDescription: String? {
        switch self {
        case .noVault:
            return "Pick a vault folder in Settings before saving."
        case .noVideoTrack:
            return "The downloaded post had no playable video. It may be a photo-only post or a carousel without video."
        case .downloadFailed(let e):
            return "Couldn't download the video. Check your internet connection and try again. (\(e.localizedDescription))"
        case .framesFailed(let e):
            return "Couldn't extract frames from the video. Try a different post. (\(e.localizedDescription))"
        case .speechFailed(let e):
            return "Couldn't transcribe the audio. The video will still be saved without a transcript. (\(e.localizedDescription))"
        case .writeFailed(let e):
            return "Couldn't write to the vault folder. Check that the folder still exists and Youty can write to it. (\(e.localizedDescription))"
        }
    }
}

/// Platform-neutral preview shown to the user before they decide to save.
struct ShortFormPreview: Sendable {
    let platform: Platform
    let title: String                   // displayed at the top of the preview
    let descriptionText: String         // caption / description body
    let author: String                  // "@username"
    let authorDisplayName: String?
    let postedAt: Date?
    let duration: TimeInterval
    let width: Int
    let height: Int

    let videoCDNURL: URL
    let videoDownloadHeaders: [String: String]

    /// Captions / auto-subtitles already exposed by the platform. When
    /// non-nil we skip on-device ASR and use these directly. (TikTok often
    /// has them; Instagram never does.)
    let prefetchedTranscript: [TranscriptSegment]?

    // Raw structured data carried through so the writer can render full
    // YAML frontmatter without us having to flatten everything here.
    let tikTokMetadata: TikTokMetadata?
    let instagramMetadata: InstagramMetadata?
}

/// Outcome of a save call.
struct ShortFormSaveResult {
    let folder: URL
    let framesWritten: Int
    let transcriptSegments: Int
    let totalMs: Int
}

@MainActor
final class ShortFormPipeline {

    private let vault: VaultManager
    private let instagram: InstagramExtractor
    private let settings: SettingsStore

    init(vault: VaultManager, settings: SettingsStore) {
        self.vault = vault
        self.settings = settings
        self.instagram = InstagramExtractor()
    }

    /// Attach the Instagram extractor's WebView to the app window so its
    /// React app has a real layout context. Call once on app launch.
    func attach(to window: NSWindow) {
        instagram.attachToWindow(window)
    }

    // MARK: - Preview

    /// Fast metadata + video-URL fetch. Should complete in <1 s for TikTok
    /// (URLSession scrape) and 1–3 s for Instagram (WKWebView render).
    func preview(url: URL) async throws -> ShortFormPreview {
        guard let platform = PlatformRouter.platform(for: url.absoluteString) else {
            throw URLError(.unsupportedURL)
        }
        switch platform {
        case .tiktok:
            let r = try await TikTokExtractor.extract(url: url)
            let title = Self.displayTitle(
                caption: r.metadata.description,
                platform: .tiktok,
                author: r.metadata.author
            )
            return ShortFormPreview(
                platform: .tiktok,
                title: title,
                descriptionText: r.metadata.description,
                author: r.metadata.author,
                authorDisplayName: r.metadata.authorDisplayName,
                postedAt: r.metadata.postedAt,
                duration: r.metadata.duration,
                width: r.metadata.width,
                height: r.metadata.height,
                videoCDNURL: r.videoCDNURL,
                videoDownloadHeaders: r.videoDownloadHeaders,
                prefetchedTranscript: r.captions,
                tikTokMetadata: r.metadata,
                instagramMetadata: nil
            )
        case .instagram:
            let r = try await instagram.extract(url: url)
            let title = Self.displayTitle(
                caption: r.metadata.caption,
                platform: .instagram,
                author: r.metadata.author
            )
            return ShortFormPreview(
                platform: .instagram,
                title: title,
                descriptionText: r.metadata.caption,
                author: r.metadata.author,
                authorDisplayName: r.metadata.authorDisplayName,
                postedAt: r.metadata.postedAt,
                duration: r.metadata.duration,
                width: r.metadata.width,
                height: r.metadata.height,
                videoCDNURL: r.videoCDNURL,
                videoDownloadHeaders: r.videoDownloadHeaders,
                prefetchedTranscript: nil,
                tikTokMetadata: nil,
                instagramMetadata: r.metadata
            )
        case .youtube:
            // Not handled here — YouTube goes through TranscriptLoader.
            throw URLError(.unsupportedURL)
        }
    }

    // MARK: - Save

    /// Materialises the preview into the vault: writes video.md, downloads
    /// the CDN bytes, extracts frames + transcript in parallel, writes JPEGs.
    /// `stage` reports progress to the UI.
    func save(preview: ShortFormPreview,
              stage: @escaping @Sendable (FrameStage) -> Void) async throws -> ShortFormSaveResult {
        guard let vaultURL = vault.vaultURL else { throw ShortFormPipelineError.noVault }
        let started = Date()
        DebugLog.log("shortform: starting save for platform=\(preview.platform.rawValue) duration=\(preview.duration)s")

        // 1. Compute folder name + initial markdown (frontmatter + caption +
        //    transcript-if-already-present, else placeholder).
        //    Path: {vault}/{platform}/{bundle}. Matches the per-platform
        //    layout the YouTube path now also uses, so the vault has one
        //    tree per platform — easier for humans and AI consumers to
        //    filter, no cross-platform name collisions.
        let folderName = Self.bundleFolderName(for: preview)
        let platformFolder = vaultURL.appendingPathComponent(preview.platform.rawValue)
        let folderURL = platformFolder.appendingPathComponent(folderName)
        // Try to acquire security-scoped access (required for user-chosen
        // folders persisted via bookmark). For paths that are already
        // accessible (e.g. the app container's temp dir during tests), this
        // call returns false but we can proceed regardless — actual file
        // operations will surface their own errors if denied.
        let acquired = vaultURL.startAccessingSecurityScopedResource()
        defer { if acquired { vaultURL.stopAccessingSecurityScopedResource() } }

        do {
            try FileManager.default.createDirectory(at: platformFolder, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        } catch {
            throw ShortFormPipelineError.writeFailed(error)
        }

        let initialMd = Self.composeMarkdown(preview: preview,
                                              transcript: preview.prefetchedTranscript)
        let videoMdURL = folderURL.appendingPathComponent("video.md")
        do {
            try initialMd.write(to: videoMdURL, atomically: true, encoding: .utf8)
        } catch {
            throw ShortFormPipelineError.writeFailed(error)
        }
        stage(.loading)

        // 2. Download CDN video to temp file.
        stage(.downloading(0))
        let downloadStart = Date()
        let tempFileURL: URL
        do {
            tempFileURL = try await MediaDownloader.download(
                url: preview.videoCDNURL,
                headers: preview.videoDownloadHeaders,
                progress: { p in Task { @MainActor in stage(.downloading(p)) } }
            )
        } catch {
            throw ShortFormPipelineError.downloadFailed(error)
        }
        let dlMs = Int(Date().timeIntervalSince(downloadStart) * 1000)
        DebugLog.log("shortform: download done in \(dlMs)ms file=\(tempFileURL.lastPathComponent)")

        // 3. Reconcile duration from the downloaded file. Instagram's JSON
        //    often omits `video_duration` for Reels (their REST API has
        //    inconsistent population); reading it from the actual MP4 via
        //    AVURLAsset is the source of truth. Use the larger of (preview,
        //    file) so we never under-count frames.
        let trueDuration = await Self.resolveDuration(
            previewDuration: preview.duration,
            fileURL: tempFileURL
        )
        DebugLog.log("shortform: duration resolved preview=\(preview.duration)s file=\(trueDuration)s")

        // 4. In parallel: frames + (if needed) ASR transcript.
        stage(.extracting(0))
        let frameTimes = FrameExtractor.frameTimes(
            duration: trueDuration,
            countCap: settings.frameCountCap,
            fpsCap: settings.fpsCap
        )
        DebugLog.log("shortform: requesting \(frameTimes.count) frames (cap=\(settings.frameCountCap) fps=\(settings.fpsCap))")

        let maxEdge = Self.maxLongEdge(for: preview, target: settings.targetResolution)
        DebugLog.log("shortform: target=\(settings.targetResolution)p source=\(preview.width)x\(preview.height) → maxLongEdge=\(maxEdge)")
        let fileBox = SendableURL(tempFileURL)

        async let framesTask: [(timestamp: TimeInterval, image: NSImage)] = {
            do {
                return try await LocalFrameExtractor.extract(
                    fileURL: fileBox.value,
                    timestamps: frameTimes,
                    maxLongEdge: maxEdge,
                    progress: { p in Task { @MainActor in stage(.extracting(p)) } }
                )
            } catch {
                throw ShortFormPipelineError.framesFailed(error)
            }
        }()

        // ASR only when there are no prefetched captions.
        let chosenLocale = settings.resolvedTranscriptionLocale()
        async let transcriptTask: [TranscriptSegment]? = {
            if let pre = preview.prefetchedTranscript { return pre }
            do {
                let segs = try await SpeechTranscriptionPipeline.transcribe(
                    audioURL: fileBox.value,
                    locale: chosenLocale
                )
                return segs
            } catch {
                DebugLog.log("shortform: ASR failed (\(error.localizedDescription)) — note will save without transcript")
                return []
            }
        }()

        let frames: [(timestamp: TimeInterval, image: NSImage)]
        let transcript: [TranscriptSegment]?
        do {
            frames = try await framesTask
            transcript = await transcriptTask
        } catch let e as ShortFormPipelineError {
            MediaDownloader.remove(tempFileURL)
            throw e
        } catch {
            MediaDownloader.remove(tempFileURL)
            throw ShortFormPipelineError.framesFailed(error)
        }
        DebugLog.log("shortform: \(frames.count) frames, \(transcript?.count ?? 0) transcript segments")

        // 4. Re-write video.md now that we have the real transcript.
        let finalMd = Self.composeMarkdown(preview: preview, transcript: transcript,
                                            durationOverride: trueDuration)
        do {
            try finalMd.write(to: videoMdURL, atomically: true, encoding: .utf8)
        } catch {
            MediaDownloader.remove(tempFileURL)
            throw ShortFormPipelineError.writeFailed(error)
        }

        // 5. Write JPEGs (parallel encode, sequential disk write — same as
        //    YouTube path). Filenames = timestamp_ms zero-padded to 8 digits.
        stage(.writing)
        let extractorFrames = frames.map { FrameExtractor.Frame(timestamp: $0.timestamp, image: $0.image) }
        do {
            try vault.writeFrames(extractorFrames, to: folderURL)
        } catch {
            MediaDownloader.remove(tempFileURL)
            throw ShortFormPipelineError.writeFailed(error)
        }

        MediaDownloader.remove(tempFileURL)

        // 6. Refresh manifest so any AI tool can find the new bundle.
        vault.regenerateManifest()

        let totalMs = Int(Date().timeIntervalSince(started) * 1000)
        return ShortFormSaveResult(
            folder: folderURL,
            framesWritten: frames.count,
            transcriptSegments: transcript?.count ?? 0,
            totalMs: totalMs
        )
    }

    // MARK: - Title selection

    /// Display title shown to the user in the UI preview and written into
    /// `video.md`'s `title:` frontmatter field. Three-step heuristic:
    ///   1. First non-empty line of the caption, stripped of *boundary*
    ///      hashtags / mentions (preserves mid-sentence ones).
    ///   2. First sentence of the flattened caption, same stripping.
    ///   3. "{Platform} by {author}" fallback for hashtag-only or empty
    ///      captions.
    /// Truncated to ~80 chars at a word boundary.
    private static func displayTitle(caption: String,
                                      platform: Platform,
                                      author: String) -> String {
        if let clean = cleanCaptionFirstSlice(caption), !clean.isEmpty {
            return clean
        }
        let platformName: String
        switch platform {
        case .tiktok:    platformName = "TikTok"
        case .instagram: platformName = "Reel"
        case .youtube:   platformName = "Video"
        }
        return author.isEmpty ? platformName : "\(platformName) by \(author)"
    }

    /// Folder-name title slice. Uses the same caption heuristic but the
    /// empty-caption fallback is the post id — without that, every
    /// caption-less Reel would land in `{author} - Reel by @{author}/`
    /// which duplicates the author.
    private static func folderTitle(caption: String, postID: String) -> String {
        if let clean = cleanCaptionFirstSlice(caption), !clean.isEmpty {
            return clean
        }
        return postID
    }

    /// Returns a clean title-ish slice of the caption, or nil when there's
    /// nothing useful (hashtag-only, empty, etc.). Shared by `displayTitle`
    /// and `folderTitle`.
    private static func cleanCaptionFirstSlice(_ caption: String) -> String? {
        let trimmed = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 1. First non-empty line with boundary hashtags/mentions removed.
        if let firstLine = trimmed.components(separatedBy: .newlines)
            .lazy.map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty }) {
            let cleaned = stripBoundaryTagsAndMentions(firstLine)
            if !cleaned.isEmpty { return truncateAtWordBoundary(cleaned, max: 80) }
        }

        // 2. First sentence of the flattened caption (handles the
        //    "single-line stream of consciousness" shape).
        let flat = trimmed.replacingOccurrences(of: "\n", with: " ")
        let cleanedAll = stripBoundaryTagsAndMentions(flat)
        if let firstSentence = cleanedAll.components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .lazy.map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty }) {
            return truncateAtWordBoundary(firstSentence, max: 80)
        }
        return nil
    }

    /// Removes leading and trailing tokens that begin with `#` or `@`.
    /// Mid-sentence tags are preserved — they're often semantically part
    /// of the caption ("10 reasons #productivity matters").
    private static func stripBoundaryTagsAndMentions(_ s: String) -> String {
        var tokens = s.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        while let first = tokens.first,
              first.hasPrefix("#") || first.hasPrefix("@") {
            tokens.removeFirst()
        }
        while let last = tokens.last,
              last.hasPrefix("#") || last.hasPrefix("@") {
            tokens.removeLast()
        }
        return tokens.joined(separator: " ")
    }

    /// Truncates to at most `max` characters; prefers a word boundary cut
    /// when one exists in the back half of the string.
    private static func truncateAtWordBoundary(_ s: String, max maxLen: Int) -> String {
        if s.count <= maxLen { return s }
        let head = String(s.prefix(maxLen))
        if let lastSpace = head.lastIndex(of: " ") {
            let pos = head.distance(from: head.startIndex, to: lastSpace)
            if pos >= maxLen / 2 {
                return String(head[..<lastSpace])
            }
        }
        return head
    }

    // MARK: - Folder naming

    /// Folder is `{Author} - {Title}` sanitised, just like YouTube. When the
    /// caption is empty or hashtag-only the title falls back to the post id
    /// (rather than "Reel by @{author}", which would duplicate the author).
    private static func bundleFolderName(for p: ShortFormPreview) -> String {
        let authorBare = p.author.hasPrefix("@") ? String(p.author.dropFirst()) : p.author
        let caption: String
        let postID: String
        switch p.platform {
        case .tiktok:
            caption = p.tikTokMetadata?.description ?? ""
            postID  = p.tikTokMetadata?.videoID ?? "post"
        case .instagram:
            caption = p.instagramMetadata?.caption ?? ""
            postID  = p.instagramMetadata?.shortcode ?? "post"
        case .youtube:
            caption = p.descriptionText
            postID  = "post"
        }
        let title = folderTitle(caption: caption, postID: postID)
        let combined = authorBare.isEmpty ? title : "\(authorBare) - \(title)"
        return sanitize(combined)
    }

    private static func sanitize(_ s: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let cleaned = s.unicodeScalars
            .filter { !forbidden.contains($0) }
            .map(Character.init)
        let collapsed = String(cleaned)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return String(collapsed.prefix(80)).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Max long edge per source

    private static func maxLongEdge(for p: ShortFormPreview, target: Int) -> Int {
        // For short-form posts the platform serves a single video file, so
        // "stream selection" is trivial — there's nothing to pick between.
        // The target setting still applies as a *cap*: if the source long
        // edge exceeds the target's nominal long edge, downscale to the
        // target. If the source is already at or below the target, save at
        // native (never upscale).
        //
        // Target → long-edge pixel count (matches FastFramePipeline.maxEdgeFor):
        //   720p  → 1280, 1080p → 1920, 1440p → 2560, 2160p → 3840
        let targetEdge: Int
        switch target {
        case 720:  targetEdge = 1280
        case 1080: targetEdge = 1920
        case 1440: targetEdge = 2560
        case 2160: targetEdge = 3840
        default:   targetEdge = 1920
        }
        let sourceEdge = max(p.width, p.height)
        // If we don't know the source resolution (0 from a missing metadata
        // field), fall back to the target — better to cap than to leak full
        // native pixels on an unknown source.
        if sourceEdge <= 0 { return targetEdge }
        return min(sourceEdge, targetEdge)
    }

    // MARK: - Duration resolution

    /// Reads the actual playable duration from a downloaded media file using
    /// AVURLAsset. Instagram's REST response often omits `video_duration` for
    /// Reels, so we treat the file as the source of truth. Returns the larger
    /// of (preview, file) to avoid ever under-counting frames; falls back to
    /// the preview value if the asset can't be loaded.
    private static func resolveDuration(previewDuration: TimeInterval,
                                         fileURL: URL) async -> TimeInterval {
        let asset = AVURLAsset(url: fileURL)
        do {
            let cm = try await asset.load(.duration)
            let fileSec = cm.seconds
            if fileSec.isFinite && fileSec > 0 {
                return max(previewDuration, fileSec)
            }
        } catch {
            DebugLog.log("shortform: AVURLAsset.duration failed (\(error.localizedDescription)) — using preview duration \(previewDuration)s")
        }
        return previewDuration
    }

    // MARK: - Markdown composition

    private static func composeMarkdown(preview p: ShortFormPreview,
                                         transcript: [TranscriptSegment]?,
                                         durationOverride: TimeInterval? = nil) -> String {
        // Use the file-derived duration when available; many Instagram Reels
        // come back from the API without `video_duration` populated.
        let effectiveDuration = (durationOverride ?? 0) > 0 ? (durationOverride ?? p.duration) : p.duration
        var lines: [String] = []
        lines.append("---")
        switch p.platform {
        case .tiktok:
            lines.append(contentsOf: yamlTikTok(p, durationOverride: effectiveDuration))
        case .instagram:
            lines.append(contentsOf: yamlInstagram(p, durationOverride: effectiveDuration))
        default:
            break
        }
        lines.append("---")
        lines.append("")

        // Description / caption section.
        let label = (p.platform == .tiktok) ? "Description" : "Caption"
        if !p.descriptionText.isEmpty {
            lines.append("## \(label)")
            lines.append("")
            lines.append(p.descriptionText)
            lines.append("")
        }

        // Transcript section.
        lines.append("## Transcript")
        lines.append("")
        if let transcript, !transcript.isEmpty {
            for seg in transcript {
                lines.append("[\(seg.timestamp)] \(seg.text)")
            }
        } else if transcript == nil {
            lines.append("_Transcript will be generated when you Save to Vault._")
        } else {
            lines.append("_No speech detected._")
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func yamlTikTok(_ p: ShortFormPreview, durationOverride: TimeInterval) -> [String] {
        guard let m = p.tikTokMetadata else { return [] }
        let dur = durationOverride > 0 ? durationOverride : m.duration
        var out: [String] = []
        out.append("title: \(yamlString(p.title))")
        out.append("platform: tiktok")
        out.append("post_id: \(yamlString(m.videoID))")
        out.append("url: \(m.url)")
        out.append("author: \(yamlString(m.author))")
        if !m.authorDisplayName.isEmpty {
            out.append("author_display_name: \(yamlString(m.authorDisplayName))")
        }
        if let posted = m.postedAt {
            out.append("posted_at: \(ISO8601DateFormatter().string(from: posted))")
        }
        out.append("date_saved: \(ISO8601DateFormatter().string(from: Date()))")
        out.append("duration: \(yamlString(formatDuration(dur)))")
        if let v = m.plays    { out.append("plays: \(v)") }
        if let v = m.likes    { out.append("likes: \(v)") }
        if let v = m.comments { out.append("comments: \(v)") }
        if let v = m.shares   { out.append("shares: \(v)") }
        if let v = m.saves    { out.append("saves: \(v)") }
        if let t = m.musicTitle  { out.append("music_title: \(yamlString(t))") }
        if let a = m.musicAuthor { out.append("music_author: \(yamlString(a))") }
        if !m.hashtags.isEmpty {
            out.append("hashtags: [\(m.hashtags.map(yamlString).joined(separator: ", "))]")
        }
        if m.width > 0 && m.height > 0 {
            out.append("resolution: \"\(m.width)x\(m.height)\"")
        }
        if m.width > 0 && m.height > 0 {
            out.append("aspect_ratio: \"\(m.width):\(m.height)\"")
        }
        return out
    }

    private static func yamlInstagram(_ p: ShortFormPreview, durationOverride: TimeInterval) -> [String] {
        guard let m = p.instagramMetadata else { return [] }
        let dur = durationOverride > 0 ? durationOverride : m.duration
        var out: [String] = []
        out.append("title: \(yamlString(p.title))")
        out.append("platform: instagram")
        out.append("post_id: \(yamlString(m.shortcode))")
        out.append("url: \(m.url)")
        out.append("author: \(yamlString(m.author))")
        if let dn = m.authorDisplayName, !dn.isEmpty {
            out.append("author_display_name: \(yamlString(dn))")
        }
        if let posted = m.postedAt {
            out.append("posted_at: \(ISO8601DateFormatter().string(from: posted))")
        }
        out.append("date_saved: \(ISO8601DateFormatter().string(from: Date()))")
        out.append("duration: \(yamlString(formatDuration(dur)))")
        if let v = m.likes    { out.append("likes: \(v)") }
        if let v = m.comments { out.append("comments: \(v)") }
        if let v = m.views    { out.append("views: \(v)") }
        if let t = m.musicTitle  { out.append("music_title: \(yamlString(t))") }
        if let a = m.musicAuthor { out.append("music_author: \(yamlString(a))") }
        if !m.hashtags.isEmpty {
            out.append("hashtags: [\(m.hashtags.map(yamlString).joined(separator: ", "))]")
        }
        if m.width > 0 && m.height > 0 {
            out.append("resolution: \"\(m.width)x\(m.height)\"")
        }
        if m.width > 0 && m.height > 0 {
            out.append("aspect_ratio: \"\(m.width):\(m.height)\"")
        }
        return out
    }

    private static func yamlString(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
                       .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func formatDuration(_ s: TimeInterval) -> String {
        let total = Int(s)
        let h = total / 3600, m = (total % 3600) / 60, sec = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                     : String(format: "%d:%02d", m, sec)
    }
}

final class SendableURL: @unchecked Sendable {
    let value: URL
    init(_ v: URL) { value = v }
}

// MARK: - SwiftUI glue

/// Thin ObservableObject wrapper so ContentView can hold a single
/// ShortFormPipeline via @StateObject (the pipeline owns a WKWebView, so we
/// want exactly one instance per app session).
@MainActor
final class ShortFormPipelineHolder: ObservableObject {
    private var _pipeline: ShortFormPipeline?
    func pipeline(vault: VaultManager, settings: SettingsStore) -> ShortFormPipeline {
        if let p = _pipeline { return p }
        let p = ShortFormPipeline(vault: vault, settings: settings)
        _pipeline = p
        return p
    }
}

/// Builds the markdown preview displayed in the result area for IG/TikTok
/// extractions. Mirrors what saveToVault() will write into `video.md` (plus a
/// title line on top so the UI has something prominent to show).
enum ShortFormMarkdownPreview {
    static func build(_ p: ShortFormPreview) -> String {
        var s = ""
        if !p.title.isEmpty {
            s += "# \(p.title)\n\n"
        }
        // Author line.
        if !p.author.isEmpty {
            if let dn = p.authorDisplayName, !dn.isEmpty, dn != p.author {
                s += "*\(dn) — \(p.author)*\n\n"
            } else {
                s += "*\(p.author)*\n\n"
            }
        }
        // Description / caption body.
        if !p.descriptionText.isEmpty {
            s += "\(p.descriptionText)\n\n"
        }
        // Transcript (only if we already have it — i.e. TikTok with auto captions).
        if let segs = p.prefetchedTranscript, !segs.isEmpty {
            s += "## Transcript\n\n"
            for seg in segs {
                s += "[\(seg.timestamp)] \(seg.text)\n"
            }
        } else {
            s += "_Transcript will be generated on save._"
        }
        return s
    }
}
