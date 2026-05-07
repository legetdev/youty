import Foundation
import AppKit

@MainActor
final class VaultManager: NSObject, ObservableObject {

    enum FrameState: Equatable {
        case idle
        case extracting
        case done
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

    // Writes the .md note instantly.
    // Checks for duplicates first — if this video_id already exists in the vault,
    // the old note and its frames folder are removed before writing the new one.
    // Updates manifest.json after writing.
    @discardableResult
    func saveNote(result: FetchResult, metadata: VideoMetadata) throws -> URL {
        guard let vault = vaultURL else { throw VaultError.noVault }
        guard vault.startAccessingSecurityScopedResource() else { throw VaultError.accessDenied }
        defer { vault.stopAccessingSecurityScopedResource() }

        let fm = FileManager.default

        // Write the new note first, then remove any old duplicate.
        // This order ensures we never lose data if the write fails.
        let noteURL = vault.appendingPathComponent(noteFilename(metadata: metadata))
        try composeNote(metadata: metadata, segments: result.segments)
            .write(to: noteURL, atomically: true, encoding: .utf8)

        // Remove old note for same video_id if it exists under a different filename.
        if let existing = findExistingEntry(videoID: metadata.videoID, in: vault),
           existing.file != noteURL.lastPathComponent {
            let oldNote   = vault.appendingPathComponent(existing.file)
            let oldFrames = vault.appendingPathComponent(existing.videoID)
            try? fm.removeItem(at: oldNote)
            try? fm.removeItem(at: oldFrames)
        }

        updateManifest(in: vault)
        return vault
    }

    // Fires after saveNote. Extracts frames directly from the stream URL via AVURLAsset —
    // no full video download. AVFoundation issues HTTP range requests only for the
    // keyframes near each target timestamp, keeping total data fetched to ~20–50MB
    // regardless of video length. Runs fully in background; UI updates via frameState.
    func extractFramesInBackground(videoID: String, streamURL: URL) {
        frameState = .extracting
        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            do {
                let frames = try await FrameExtractor.extract(from: streamURL)

                guard let vault = await self.vaultURL else { return }
                guard vault.startAccessingSecurityScopedResource() else { return }
                defer { vault.stopAccessingSecurityScopedResource() }

                let framesDir = vault.appendingPathComponent(videoID)
                try FileManager.default.createDirectory(at: framesDir,
                                                        withIntermediateDirectories: true)
                for frame in frames {
                    let name = String(format: "%04d.jpg", Int(frame.timestamp))
                    if let data = frame.image.jpegData(compressionQuality: 0.82) {
                        try? data.write(to: framesDir.appendingPathComponent(name))
                    }
                }

                await MainActor.run { self.frameState = .done }

            } catch {
                let msg = error.localizedDescription
                await MainActor.run { self.frameState = .failed(msg) }
            }
        }
    }

    // MARK: - Manifest

    struct ManifestEntry: Codable {
        let file:       String
        let videoID:    String
        let title:      String
        let channel:    String
        let duration:   String
        let dateSaved:  String
        let tags:       [String]
        let url:        String

        enum CodingKeys: String, CodingKey {
            case file, title, channel, duration, tags, url
            case videoID   = "video_id"
            case dateSaved = "date_saved"
        }
    }

    // Rebuilds manifest.json from all .md files in the vault.
    // Called automatically after every saveNote().
    private func updateManifest(in vault: URL) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: vault,
                                                          includingPropertiesForKeys: nil) else { return }
        var entries: [ManifestEntry] = []
        for url in contents where url.pathExtension == "md" {
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  let entry = manifestEntry(from: text, filename: url.lastPathComponent) else { continue }
            entries.append(entry)
        }
        entries.sort { $0.dateSaved > $1.dateSaved }  // newest first
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(entries) {
            try? data.write(to: vault.appendingPathComponent("manifest.json"), options: .atomic)
        }
    }

    // Finds an existing manifest entry for a given video_id.
    // Reads manifest.json if it exists; otherwise scans all .md files.
    private func findExistingEntry(videoID: String, in vault: URL) -> ManifestEntry? {
        let manifestURL = vault.appendingPathComponent("manifest.json")
        if let data = try? Data(contentsOf: manifestURL),
           let entries = try? JSONDecoder().decode([ManifestEntry].self, from: data) {
            return entries.first { $0.videoID == videoID }
        }
        // Fallback: scan files directly
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: vault,
                                                          includingPropertiesForKeys: nil) else { return nil }
        for url in contents where url.pathExtension == "md" {
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  let entry = manifestEntry(from: text, filename: url.lastPathComponent),
                  entry.videoID == videoID else { continue }
            return entry
        }
        return nil
    }

    // Parses YAML frontmatter from a note file into a ManifestEntry.
    private func manifestEntry(from text: String, filename: String) -> ManifestEntry? {
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

        guard let videoID = kv["video_id"], !videoID.isEmpty else { return nil }

        // Parse tags: ["tag1", "tag2"] → [String]
        let tagsRaw = kv["tags"] ?? "[]"
        let tags = tagsRaw
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            .filter { !$0.isEmpty }

        return ManifestEntry(
            file:      filename,
            videoID:   videoID,
            title:     kv["title"]      ?? "",
            channel:   kv["channel"]    ?? "",
            duration:  kv["duration"]   ?? "",
            dateSaved: kv["date_saved"] ?? "",
            tags:      tags,
            url:       kv["url"]        ?? "https://www.youtube.com/watch?v=\(videoID)"
        )
    }

    // MARK: - Filename

    private func noteFilename(metadata: VideoMetadata) -> String {
        let channel = sanitize(metadata.channel)
        let title   = sanitize(metadata.title)
        let name    = channel.isEmpty ? title : "\(channel) - \(title)"
        return name.isEmpty ? "\(metadata.videoID).md" : "\(name).md"
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
            "video_id: \(metadata.videoID)",
            "url: https://www.youtube.com/watch?v=\(metadata.videoID)",
            "channel: \"\(metadata.channel)\"",
            "duration: \"\(formatDuration(metadata.durationSeconds))\"",
            "date_saved: \(metadata.dateSaved)",
            "tags: [\(tags)]",
            "frames_dir: \(metadata.videoID)/",
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
        // Validate the resolved URL is a real accessible directory, not file:/// or garbage.
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
