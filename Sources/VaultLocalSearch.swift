import Foundation

// Lightweight local search over the vault — used by AppIntents
// (SearchYoutyVaultIntent + GetYoutyTranscriptIntent) and the menu bar
// popover's recents list. Deliberately does *not* depend on the SQLite
// vector index, MobileCLIP, or any embedder — those are heavier than the
// 50-ms budget AppIntents typically have, and Shortcuts users mostly want
// keyword recall ("the Karpathy video I saved last week").
//
// Source of truth: manifest.json at the vault root. Falls back to scanning
// bundles on disk if the manifest is missing (first save after fresh
// vault). Transcript reads are direct from video.md.

@MainActor
enum VaultLocalSearch {

    struct Match {
        let videoID:   String
        let title:     String
        let channel:   String
        let platform:  String
        let url:       String
        let folder:    URL
        let dateSaved: String
    }

    struct Transcript {
        let title: String
        let text:  String
    }

    // MARK: - Search

    /// Keyword search: token-AND match against title + channel + tags. Tied
    /// scores break by recency (date_saved). Tokens are lowercased and any
    /// punctuation is stripped.
    static func search(query: String, limit: Int) -> [Match] {
        let entries = loadManifestEntries()
        guard !entries.isEmpty else { return [] }
        let tokens = tokenize(query)
        guard !tokens.isEmpty else { return [] }

        var scored: [(Match, Int)] = []
        for entry in entries {
            let haystack = ([entry.title, entry.channel] + entry.tags + [entry.platform])
                .joined(separator: " ")
                .lowercased()
            var allMatched = true
            var score = 0
            for token in tokens {
                if haystack.contains(token) {
                    score += haystack.contains(" " + token) || haystack.hasPrefix(token) ? 2 : 1
                } else {
                    allMatched = false
                    break
                }
            }
            if allMatched {
                guard let folder = bundleFolderURL(for: entry) else { continue }
                scored.append((
                    Match(
                        videoID:   entry.videoID,
                        title:     entry.title,
                        channel:   entry.channel,
                        platform:  entry.platform,
                        url:       entry.url,
                        folder:    folder,
                        dateSaved: entry.dateSaved
                    ),
                    score
                ))
            }
        }
        let sorted = scored.sorted { a, b in
            if a.1 != b.1 { return a.1 > b.1 }
            return a.0.dateSaved > b.0.dateSaved
        }
        return Array(sorted.prefix(limit).map { $0.0 })
    }

    // MARK: - Transcript lookup

    /// Locate a saved video by URL, full bundle path, or platform-qualified
    /// id ("yt:abc123", "ig:DEF456", "tt:7234…"), and return its transcript
    /// body. Returns nil if no match.
    static func transcript(forIdentifier raw: String) -> Transcript? {
        let needle = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return nil }
        let entries = loadManifestEntries()
        guard let entry = entries.first(where: { entry in
            if entry.url.lowercased() == needle { return true }
            if needle.contains(entry.videoID.lowercased()) { return true }
            let qualified = "\(platformPrefix(entry.platform)):\(entry.videoID)".lowercased()
            return needle == qualified || needle.hasSuffix(qualified)
        }) else { return nil }
        guard let folder = bundleFolderURL(for: entry) else { return nil }
        let noteURL = folder.appendingPathComponent("video.md")
        let acquired = vaultRootURL()?.startAccessingSecurityScopedResource() ?? false
        defer {
            if acquired { vaultRootURL()?.stopAccessingSecurityScopedResource() }
        }
        guard let text = try? String(contentsOf: noteURL, encoding: .utf8) else { return nil }
        let body = stripFrontmatter(text)
        return Transcript(title: entry.title, text: body)
    }

    // MARK: - Recents (for menu bar popover)

    /// Most recently saved bundles. Same input as `search` but sorted by
    /// date_saved descending with no filter.
    static func recents(limit: Int) -> [Match] {
        let entries = loadManifestEntries()
            .sorted { $0.dateSaved > $1.dateSaved }
            .prefix(limit)
        return entries.compactMap { entry in
            guard let folder = bundleFolderURL(for: entry) else { return nil }
            return Match(
                videoID:   entry.videoID,
                title:     entry.title,
                channel:   entry.channel,
                platform:  entry.platform,
                url:       entry.url,
                folder:    folder,
                dateSaved: entry.dateSaved
            )
        }
    }

    // MARK: - Manifest loading

    private static func loadManifestEntries() -> [VaultManager.ManifestEntry] {
        guard let vault = vaultRootURL() else { return [] }
        let acquired = vault.startAccessingSecurityScopedResource()
        defer { if acquired { vault.stopAccessingSecurityScopedResource() } }
        let manifestURL = vault.appendingPathComponent("manifest.json")
        if let data = try? Data(contentsOf: manifestURL),
           let entries = try? JSONDecoder().decode([VaultManager.ManifestEntry].self, from: data) {
            return entries
        }
        // Manifest missing — best-effort rebuild + retry.
        VaultManager.writeManifest(in: vault)
        if let data = try? Data(contentsOf: manifestURL),
           let entries = try? JSONDecoder().decode([VaultManager.ManifestEntry].self, from: data) {
            return entries
        }
        return []
    }

    static func vaultRootURL() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: "vaultBookmark") else { return nil }
        var stale = false
        return try? URL(resolvingBookmarkData: data,
                        options: .withSecurityScope,
                        relativeTo: nil,
                        bookmarkDataIsStale: &stale)
    }

    private static func bundleFolderURL(for entry: VaultManager.ManifestEntry) -> URL? {
        guard let vault = vaultRootURL() else { return nil }
        return vault.appendingPathComponent(entry.folder)
    }

    // MARK: - Helpers

    private static func tokenize(_ s: String) -> [String] {
        s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
    }

    private static func stripFrontmatter(_ text: String) -> String {
        guard text.hasPrefix("---") else { return text }
        let lines = text.components(separatedBy: "\n")
        guard let close = lines.dropFirst().firstIndex(of: "---") else { return text }
        return lines.suffix(from: close + 1).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func platformPrefix(_ platform: String) -> String {
        switch platform {
        case "instagram": return "ig"
        case "tiktok":    return "tt"
        default:          return "yt"
        }
    }
}
