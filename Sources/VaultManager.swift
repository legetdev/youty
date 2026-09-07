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
    // Existing same-video bundles remain available until frame writing succeeds.
    @discardableResult
    func saveNote(result: FetchResult, metadata: VideoMetadata) throws -> URL {
        guard let vault = vaultURL else { throw VaultError.noVault }
        let acquired = vault.startAccessingSecurityScopedResource()
        defer { if acquired { vault.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        let folderName = bundleFolderName(metadata: metadata)
        // YouTube bundles live under {vault}/youtube/{folder}. Same shape as
        // the Instagram + TikTok paths so the corpus has one tree per
        // platform — easier for AI consumers to filter, easier for humans
        // to browse, and avoids cross-platform name collisions.
        let platformFolder = vault.appendingPathComponent("youtube")
        try fm.createDirectory(at: platformFolder, withIntermediateDirectories: true)
        let folderURL = try Self.destinationBundle(in: vault, platform: "youtube",
                                                   name: folderName, videoID: metadata.videoID)

        // Write video.md inside the new folder
        try fm.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try composeNote(metadata: metadata, segments: result.segments)
            .write(to: folderURL.appendingPathComponent("video.md"), atomically: true, encoding: .utf8)

        updateManifest(in: vault)
        return folderURL
    }

    // Writes frames into the same bundle folder as video.md.
    func writeFrames(_ frames: [FrameExtractor.Frame], to folderURL: URL) throws {
        guard let vault = vaultURL else { throw VaultError.noVault }
        let acquired = vault.startAccessingSecurityScopedResource()
        defer { if acquired { vault.stopAccessingSecurityScopedResource() } }
        let rootPath = vault.standardizedFileURL.path + "/"
        let targetPath = folderURL.standardizedFileURL.path
        guard targetPath.hasPrefix(rootPath),
              Self.bundleURL(relativePath: String(targetPath.dropFirst(rootPath.count)), in: vault) != nil else {
            throw VaultError.accessDenied
        }
        guard !frames.isEmpty,
              frames.allSatisfy({ $0.timestamp.isFinite && $0.timestamp >= 0 && $0.timestamp < Double(Int32.max) / 1000 }) else {
            throw VaultError.frameWriteFailed("No valid frames were available")
        }

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
        var encodeFailures = 0
        for frame in frames {
            group.enter()
            queue.async {
                // Round (not truncate) so float drift can't shift the ms-stem
                // off the documented exact-millisecond contract.
                let ms = Int((frame.timestamp * 1000).rounded())
                let name = String(format: "%08d.jpg", ms)
                if let data = frame.image.jpegData(compressionQuality: 0.85) {
                    lock.lock(); encoded.append((name, data)); lock.unlock()
                } else {
                    lock.lock(); encodeFailures += 1; lock.unlock()
                }
                group.leave()
            }
        }
        group.wait()
        // All-or-nothing (hard requirement: no partial / silently-padded bundle).
        // A failed encode aborts before any write; staging keeps write failures
        // from replacing the previous complete capture.
        guard encodeFailures == 0 else {
            throw VaultError.frameWriteFailed("\(encodeFailures) of \(frames.count) frame(s) failed to JPEG-encode")
        }
        let fm = FileManager.default
        let staging = folderURL.deletingLastPathComponent()
            .appendingPathComponent(".youty-frames-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staging) }
        // Replace the complete directory only after every frame is on disk;
        // failed re-saves retain prior frames and cannot leave mixed captures.
        try fm.copyItem(at: folderURL, to: staging)
        for item in try fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil) {
            if item.pathExtension.lowercased() == "jpg",
               Int(item.deletingPathExtension().lastPathComponent) != nil {
                try fm.removeItem(at: item)
            }
        }
        for (name, data) in encoded {
            let url = staging.appendingPathComponent(name)
            do {
                try data.write(to: url)
            } catch {
                throw VaultError.frameWriteFailed("couldn't write \(name): \(error.localizedDescription)")
            }
        }
        try Self.commitBundle(staged: staging, to: folderURL)
        removeSupersededYouTubeBundles(for: folderURL, in: vault)
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
        let acquired = vault.startAccessingSecurityScopedResource()
        defer { if acquired { vault.stopAccessingSecurityScopedResource() } }
        updateManifest(in: vault)
    }

    /// Stateless, non-isolated manifest rebuild. Callable from any actor —
    /// in particular from Indexer.reindexVault which runs on a background
    /// task while the main thread is blocked on `sem.wait()` in headless
    /// mode (so `MainActor.run` would deadlock).
    ///
    /// Caller is responsible for owning the security scope on `vault`
    /// (the reindex probe holds it via the stored bookmark).
    @discardableResult
    nonisolated static func rebuildManifest(at vault: URL) -> Bool {
        let manifestURL = vault.appendingPathComponent("manifest.json")
        let before = (try? FileManager.default.attributesOfItem(atPath: manifestURL.path)[.modificationDate] as? Date) ?? Date.distantPast
        VaultManager.writeManifest(in: vault)
        let after = (try? FileManager.default.attributesOfItem(atPath: manifestURL.path)[.modificationDate] as? Date) ?? Date.distantPast
        let touched = after > before
        NSLog("[vault] manifest rebuild touched=%@ path=%@", touched ? "yes" : "no", manifestURL.path)
        return touched
    }

    /// Non-isolated worker — the actual disk walk + JSON write. Pulled out
    /// of the `@MainActor`-bound `updateManifest` so the headless reindex
    /// can call it from a background task without deadlocking.
    nonisolated static func writeManifest(in vault: URL) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: vault, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }
        var entries: [ManifestEntry] = []
        let platformDirs: Set<String> = ["youtube", "tiktok", "instagram"]
        for item in contents {
            guard !item.lastPathComponent.hasPrefix(".youty-save-"),
                  !item.lastPathComponent.hasPrefix(".youty-frames-") else { continue }
            guard (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            if bundleURL(relativePath: item.lastPathComponent, in: vault) != nil,
               let entry = readBundleStatic(at: item, relativePath: item.lastPathComponent) {
                entries.append(entry)
                continue
            }
            if platformDirs.contains(item.lastPathComponent) {
                guard let inner = try? fm.contentsOfDirectory(
                    at: item, includingPropertiesForKeys: [.isDirectoryKey]
                ) else { continue }
                for bundle in inner {
                    guard !bundle.lastPathComponent.hasPrefix(".youty-save-"),
                          !bundle.lastPathComponent.hasPrefix(".youty-frames-") else { continue }
                    guard (try? bundle.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
                    let rel = "\(item.lastPathComponent)/\(bundle.lastPathComponent)"
                    if bundleURL(relativePath: rel, in: vault) != nil,
                       let entry = readBundleStatic(at: bundle, relativePath: rel) {
                        entries.append(entry)
                    }
                }
            }
        }
        entries.sort { $0.dateSaved > $1.dateSaved }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(entries) {
            try? data.write(to: vault.appendingPathComponent("manifest.json"), options: .atomic)
        }
    }

    nonisolated private static func readBundleStatic(at folderURL: URL, relativePath: String) -> ManifestEntry? {
        let noteURL = folderURL.appendingPathComponent("video.md")
        guard (try? noteURL.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true else { return nil }
        guard let text = try? String(contentsOf: noteURL, encoding: .utf8) else { return nil }
        return manifestEntryStatic(from: text, folderName: relativePath)
    }

    /// Resolves a bundle path only when it stays below the vault, including
    /// symlink resolution. Accepts legacy flat and current platform layouts.
    nonisolated static func bundleURL(relativePath: String, in vault: URL) -> URL? {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard (1...2).contains(components.count),
              !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              !relativePath.contains("\0"),
              components.count == 1 || ["youtube", "tiktok", "instagram"].contains(String(components[0])) else { return nil }
        // Resolving a nonexistent leaf can leave its symlinked ancestors
        // unresolved. Reject links component-by-component before new writes.
        var ancestor = vault
        for component in components {
            ancestor.appendPathComponent(String(component))
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: ancestor.path)) != nil {
                return nil
            }
        }
        let root = vault.resolvingSymlinksInPath().standardizedFileURL
        let candidate = vault.appendingPathComponent(relativePath)
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path.hasPrefix(root.path + "/"),
              resolved != root else { return nil }
        // A one-component platform directory is never itself a video bundle.
        guard components.count != 1 || !["youtube", "tiktok", "instagram"].contains(relativePath) else { return nil }
        return candidate
    }

    /// Commits a completed sibling directory without exposing partial contents.
    nonisolated static func commitBundle(staged: URL, to destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: staged, options: .usingNewMetadataOnly)
        } else {
            try fm.moveItem(at: staged, to: destination)
        }
    }

    /// Keeps readable titles while disambiguating different videos with the same name.
    nonisolated static func destinationBundle(in vault: URL, platform: String, name: String, videoID: String) throws -> URL {
        guard !videoID.isEmpty, videoID.count <= 64,
              videoID.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
            throw VaultError.accessDenied
        }
        let safeName = name.isEmpty || name.allSatisfy({ $0 == "." }) ? videoID : name
        for candidateName in [safeName, "\(safeName) - \(videoID)"] {
            let relative = "\(platform)/\(candidateName)"
            guard let candidate = bundleURL(relativePath: relative, in: vault) else { throw VaultError.accessDenied }
            if !FileManager.default.fileExists(atPath: candidate.path)
                || readBundleStatic(at: candidate, relativePath: relative)?.videoID == videoID {
                return candidate
            }
        }
        throw VaultError.accessDenied
    }

    /// Retires prior titles only after the replacement's frames are committed.
    private func removeSupersededYouTubeBundles(for folder: URL, in vault: URL) {
        guard folder.deletingLastPathComponent().lastPathComponent == "youtube",
              let current = Self.readBundleStatic(at: folder, relativePath: "youtube/\(folder.lastPathComponent)"),
              current.platform == "youtube",
              let currentFileID = (try? folder.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier as? NSObject,
              let data = try? Data(contentsOf: vault.appendingPathComponent("manifest.json")),
              let entries = try? JSONDecoder().decode([ManifestEntry].self, from: data) else { return }
        for entry in entries where entry.videoID == current.videoID && entry.platform == "youtube" {
            guard let oldFolder = Self.bundleURL(relativePath: entry.folder, in: vault),
                  oldFolder.standardizedFileURL != folder.standardizedFileURL,
                  let oldFileID = (try? oldFolder.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier as? NSObject,
                  !oldFileID.isEqual(currentFileID),
                  Self.readBundleStatic(at: oldFolder, relativePath: entry.folder)?.videoID == current.videoID else { continue }
            try? FileManager.default.removeItem(at: oldFolder)
        }
        updateManifest(in: vault)
    }

    nonisolated private static func manifestEntryStatic(from text: String, folderName: String) -> ManifestEntry? {
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
        let id = kv["video_id"] ?? kv["post_id"] ?? ""
        guard !id.isEmpty else { return nil }
        // Re-validate the folder path on read: write-time sanitisation only
        // protects writes made by this app. If the vault was synced from a
        // tampered source (Dropbox, iCloud, a different machine), the
        // manifest could legitimately contain `..` or absolute paths that
        // would escape the vault on subsequent writes. Reject those rows.
        let rejectsPathEscape = folderName.split(separator: "/").contains("..")
            || folderName.hasPrefix("/")
            || folderName.contains("\0")
        guard !rejectsPathEscape else { return nil }
        let platform = kv["platform"] ?? "youtube"
        let tagsRaw = kv["tags"] ?? kv["hashtags"] ?? "[]"
        let tags = tagsRaw
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            .filter { !$0.isEmpty }
        let channel = kv["channel"] ?? kv["author_display_name"] ?? kv["author"] ?? ""
        let urlFallback: String
        switch platform {
        case "tiktok":    urlFallback = "https://www.tiktok.com/"
        case "instagram": urlFallback = "https://www.instagram.com/p/\(id)/"
        default:          urlFallback = "https://www.youtube.com/watch?v=\(id)"
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

    // Scans all subfolders for video.md, rebuilds manifest.json. Recurses
    // one level so the per-platform vault layout
    // ({vault}/{youtube,tiktok,instagram}/{bundle}) is discovered uniformly
    // alongside any legacy flat bundles still living at the vault root.
    private func updateManifest(in vault: URL) {
        Self.writeManifest(in: vault)
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
        let result = String(collapsed.prefix(80)).trimmingCharacters(in: .whitespaces)
        // Reject a component that is only dots (".", "..") — it would resolve to
        // the current/parent directory. Empty → bundleFolderName falls back to
        // the video_id, keeping the write inside the platform folder.
        if result.allSatisfy({ $0 == "." }) { return "" }
        return result
    }

    // MARK: - Note composition

    /// Double-quoted YAML scalar with `\`, `"`, and newlines escaped. Without
    /// this, a video title containing a quote or newline would corrupt the
    /// frontmatter and let arbitrary YAML keys be injected into the note that
    /// the MCP / AI consumers parse. (The short-form path already escapes; this
    /// brings the YouTube path to parity.)
    private func yamlQuoted(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return "\"\(escaped)\""
    }

    private func composeNote(metadata: VideoMetadata, segments: [TranscriptSegment]) -> String {
        let tags = metadata.tags.map { yamlQuoted($0) }.joined(separator: ", ")

        var lines: [String] = [
            "---",
            "title: \(yamlQuoted(metadata.title))",
            "platform: youtube",
            "video_id: \(metadata.videoID)",
            "url: https://www.youtube.com/watch?v=\(metadata.videoID)",
            "channel: \(yamlQuoted(metadata.channel))",
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
    case frameWriteFailed(String)
    var errorDescription: String? {
        switch self {
        case .noVault:
            return "Pick a vault folder in Settings before saving."
        case .accessDenied:
            return "Youty can't write to the chosen vault folder. Pick a folder you own, or grant access in System Settings → Privacy & Security → Files & Folders."
        case .frameWriteFailed(let detail):
            return "Couldn't save all frames for this video (\(detail)). The bundle wasn't written with partial frames — try saving again."
        }
    }
}
