import Foundation
import AppKit

// Bundle structure: each video is a self-contained folder.
//
// {vault}/
//   TED - Do schools kill creativity/
//     video.md        ← note with frontmatter + transcript (written instantly)
//     0000.jpg        ← frames added in background
//     0007.jpg
//     ...
//   manifest.json     ← corpus index, updated on every save

@MainActor
final class VaultManager: NSObject, ObservableObject {

    enum FrameState: Equatable {
        case idle
        case capturingStream
        case downloading(Double)
        case extracting
        case done(Int)
        case failed(String)
    }

    private let bookmarkKey = "vaultBookmark"

    @Published var vaultURL: URL?
    @Published var frameState: FrameState = .idle

    override init() {
        super.init()
        loadBookmark()
    }

    func chooseVault() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder for Youty notes"
        panel.prompt = "Select"
        if panel.runModal() == .OK {
            vaultURL = panel.url
            saveBookmark()
        }
    }

    // Creates the video bundle folder and writes video.md instantly.
    // Returns the folder URL so frames can be written there later.
    // Removes any existing bundle for the same video_id first (safe — writes new before deleting old).
    @discardableResult
    func saveNote(result: FetchResult, metadata: VideoMetadata) throws -> URL {
        guard let vault = vaultURL else { throw VaultError.noVault }
        guard vault.startAccessingSecurityScopedResource() else { throw VaultError.accessDenied }
        defer { vault.stopAccessingSecurityScopedResource() }

        let fm = FileManager.default
        let folderName = bundleFolderName(metadata: metadata)
        let folderURL  = vault.appendingPathComponent(folderName)

        // Write video.md inside the new folder
        try fm.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try composeNote(metadata: metadata, segments: result.segments)
            .write(to: folderURL.appendingPathComponent("video.md"), atomically: true, encoding: .utf8)

        // Remove any old bundle for the same video_id (different folder name = re-saved with new title)
        if let existing = findExistingEntry(videoID: metadata.videoID, in: vault),
           existing.folder != folderName {
            try? fm.removeItem(at: vault.appendingPathComponent(existing.folder))
        }

        updateManifest(in: vault)
        return folderURL
    }

    // Writes frames into the same bundle folder as video.md.
    func writeFrames(_ frames: [FrameExtractor.Frame], to folderURL: URL) throws {
        guard let vault = vaultURL else { throw VaultError.noVault }
        let acquired = vault.startAccessingSecurityScopedResource()
        defer { if acquired { vault.stopAccessingSecurityScopedResource() } }

        // Filenames are the timestamp in milliseconds, zero-padded to 8 digits
        // (covers ≤ 27 hours). AI consumers resolve [M:SS] timestamps by
        // parsing to ms and matching the numerically closest stem.
        //
        // JPEG encoding is CPU-heavy at 1080p (~10 ms per frame). Encode all
        // frames in parallel via a concurrent dispatch group, then write
        // sequentially (file-system writes serialize anyway on a single SSD).
        let queue = DispatchQueue(label: "youty.jpeg-encode", attributes: .concurrent)
        let group = DispatchGroup()
        let lock = NSLock()
        var encoded: [(name: String, data: Data)] = []
        for frame in frames {
            group.enter()
            queue.async {
                let ms = Int(frame.timestamp * 1000)
                let name = String(format: "%08d.jpg", ms)
                if let data = frame.image.jpegData(compressionQuality: 0.85) {
                    lock.lock(); encoded.append((name, data)); lock.unlock()
                }
                group.leave()
            }
        }
        group.wait()
        for (name, data) in encoded {
            try? data.write(to: folderURL.appendingPathComponent(name))
        }
    }

    // MARK: - Manifest

    struct ManifestEntry: Codable {
        let folder:    String   // e.g. "TED - Do schools kill creativity"
        let videoID:   String
        let title:     String
        let channel:   String
        let duration:  String
        let dateSaved: String
        let tags:      [String]
        let url:       String
        let platform:  String   // "youtube", "tiktok", "instagram"

        enum CodingKeys: String, CodingKey {
            case folder, title, channel, duration, tags, url, platform
            case videoID   = "video_id"
            case dateSaved = "date_saved"
        }
    }

    /// Public manifest refresh. Called by ShortFormPipeline after writing
    /// a new IG / TikTok bundle so the corpus index picks it up immediately.
    func regenerateManifest() {
        guard let vault = vaultURL else { return }
        guard vault.startAccessingSecurityScopedResource() else { return }
        defer { vault.stopAccessingSecurityScopedResource() }
        updateManifest(in: vault)
    }

    // Scans all subfolders for video.md, rebuilds manifest.json.
    private func updateManifest(in vault: URL) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: vault,
                                                          includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        var entries: [ManifestEntry] = []
        for item in contents {
            guard (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let noteURL = item.appendingPathComponent("video.md")
            guard let text = try? String(contentsOf: noteURL, encoding: .utf8),
                  let entry = manifestEntry(from: text, folderName: item.lastPathComponent) else { continue }
            entries.append(entry)
        }
        entries.sort { $0.dateSaved > $1.dateSaved }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(entries) {
            try? data.write(to: vault.appendingPathComponent("manifest.json"), options: .atomic)
        }
    }

    // Finds an existing manifest entry by video_id. Checks manifest.json first, then scans.
    private func findExistingEntry(videoID: String, in vault: URL) -> ManifestEntry? {
        let manifestURL = vault.appendingPathComponent("manifest.json")
        if let data = try? Data(contentsOf: manifestURL),
           let entries = try? JSONDecoder().decode([ManifestEntry].self, from: data) {
            return entries.first { $0.videoID == videoID }
        }
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: vault,
                                                          includingPropertiesForKeys: [.isDirectoryKey]) else { return nil }
        for item in contents {
            guard (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let noteURL = item.appendingPathComponent("video.md")
            guard let text = try? String(contentsOf: noteURL, encoding: .utf8),
                  let entry = manifestEntry(from: text, folderName: item.lastPathComponent),
                  entry.videoID == videoID else { continue }
            return entry
        }
        return nil
    }

    private func manifestEntry(from text: String, folderName: String) -> ManifestEntry? {
        guard text.hasPrefix("---") else { return nil }
        let lines = text.components(separatedBy: "\n")
        guard let closeIdx = lines.dropFirst().firstIndex(of: "---") else { return nil }
        let frontmatter = lines[1..<closeIdx]

        var kv: [String: String] = [:]
        for line in frontmatter {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            kv[parts[0]] = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }

        // Accept either YouTube's `video_id` or short-form's `post_id`. Both
        // are universal-ish identifiers and the parser doesn't care which.
        let id = kv["video_id"] ?? kv["post_id"] ?? ""
        guard !id.isEmpty else { return nil }

        // Platform: explicit when set (IG/TikTok), else default to youtube
        // for the historical entries that predate this field.
        let platform = kv["platform"] ?? "youtube"

        // Tags / hashtags — accept either key. Hashtags from IG/TikTok serve
        // the same "topical labels" role as YouTube tags.
        let tagsRaw = kv["tags"] ?? kv["hashtags"] ?? "[]"
        let tags = tagsRaw
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            .filter { !$0.isEmpty }

        // "channel" is the canonical author label across all platforms.
        // YouTube uses `channel`, IG/TikTok use `author` / `author_display_name`.
        let channel = kv["channel"] ?? kv["author_display_name"] ?? kv["author"] ?? ""

        // url fallback varies per platform.
        let urlFallback: String
        switch platform {
        case "tiktok":   urlFallback = "https://www.tiktok.com/"
        case "instagram":urlFallback = "https://www.instagram.com/p/\(id)/"
        default:         urlFallback = "https://www.youtube.com/watch?v=\(id)"
        }

        return ManifestEntry(
            folder:    folderName,
            videoID:   id,
            title:     kv["title"]      ?? "",
            channel:   channel,
            duration:  kv["duration"]   ?? "",
            dateSaved: kv["date_saved"] ?? "",
            tags:      tags,
            url:       kv["url"]        ?? urlFallback,
            platform:  platform
        )
    }

    // MARK: - Folder naming

    // Returns the bundle folder name: "Channel - Title" (no extension).
    private func bundleFolderName(metadata: VideoMetadata) -> String {
        let channel = sanitize(metadata.channel)
        let title   = sanitize(metadata.title)
        let name    = channel.isEmpty ? title : "\(channel) - \(title)"
        return name.isEmpty ? metadata.videoID : name
    }

    private func sanitize(_ s: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let cleaned = s.unicodeScalars
            .filter { !forbidden.contains($0) }
            .map { Character($0) }
        let collapsed = String(cleaned)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return String(collapsed.prefix(80)).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Note composition

    private func composeNote(metadata: VideoMetadata, segments: [TranscriptSegment]) -> String {
        let tags = metadata.tags.map { "\"\($0)\"" }.joined(separator: ", ")

        var lines: [String] = [
            "---",
            "title: \"\(metadata.title)\"",
            "platform: youtube",
            "video_id: \(metadata.videoID)",
            "url: https://www.youtube.com/watch?v=\(metadata.videoID)",
            "channel: \"\(metadata.channel)\"",
            "duration: \"\(formatDuration(metadata.durationSeconds))\"",
            "date_saved: \(metadata.dateSaved)",
            "tags: [\(tags)]",
            "---", ""
        ]

        if !metadata.shortDescription.isEmpty {
            lines += ["## Description", "", metadata.shortDescription, ""]
        }

        if !metadata.youtubeSummary.isEmpty {
            lines += ["## Summary", "", metadata.youtubeSummary, ""]
        }

        lines += ["## Transcript", ""]
        for seg in segments {
            lines.append("[\(seg.timestamp)] \(seg.text)")
        }

        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Helpers

    private func formatDuration(_ s: Int) -> String {
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                     : String(format: "%d:%02d", m, sec)
    }

    private func saveBookmark() {
        guard let url = vaultURL,
              let data = try? url.bookmarkData(options: .withSecurityScope,
                                               includingResourceValuesForKeys: nil,
                                               relativeTo: nil) else { return }
        UserDefaults.standard.set(data, forKey: bookmarkKey)
    }

    private func loadBookmark() {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data,
                                 options: .withSecurityScope,
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else {
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
            return
        }
        guard url.path.count > 1,
              url.startAccessingSecurityScopedResource() else {
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
            return
        }
        url.stopAccessingSecurityScopedResource()
        vaultURL = url
        if stale { saveBookmark() }
    }
}

enum VaultError: LocalizedError {
    case noVault, accessDenied
    var errorDescription: String? {
        switch self {
        case .noVault:      return "No vault folder selected."
        case .accessDenied: return "Could not access the selected folder."
        }
    }
}
