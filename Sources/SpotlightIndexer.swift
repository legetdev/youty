import Foundation
@preconcurrency import CoreSpotlight
import UniformTypeIdentifiers
import AppKit

// CoreSpotlight integration: every saved video gets a CSSearchableItem so
// the user can find it from Spotlight (cmd+space) by typing the title,
// channel, or any word from the transcript.
//
// Clicking a Spotlight result opens Youty via `youty://open?folder=…`,
// which we resolve to a reveal-in-Finder on the bundle folder. We don't
// re-open the video in the main window because Youty's main UI is
// capture-oriented, not browse-oriented — the natural "I want to look at
// this saved video again" action is "show me the folder with the note
// and frames", which Finder does perfectly.
//
// Reconciliation: on every successful save we add/refresh one item. On
// app launch we don't re-index the whole vault (CoreSpotlight items
// persist across launches), but we do drop the stale items when a vault
// is deleted (best-effort, on demand).

@MainActor
enum SpotlightIndexer {

    private static let domainIdentifier = "dev.leget.youty.vault"

    /// Called after each successful save. Reads video.md to get the title,
    /// channel, and transcript snippet, then writes one CSSearchableItem.
    /// Failures are logged but never block the save flow.
    static func indexBundle(at folderURL: URL, vault: VaultManager) {
        // Reading video.md needs vault security scope.
        guard let vaultURL = vault.vaultURL else { return }
        let acquired = vaultURL.startAccessingSecurityScopedResource()
        defer { if acquired { vaultURL.stopAccessingSecurityScopedResource() } }

        let noteURL = folderURL.appendingPathComponent("video.md")
        guard let text = try? String(contentsOf: noteURL, encoding: .utf8) else { return }
        let parsed = parseFrontmatter(text)
        let videoID = parsed["video_id"] ?? parsed["post_id"] ?? folderURL.lastPathComponent
        let title    = parsed["title"]    ?? folderURL.lastPathComponent
        let channel  = parsed["channel"]  ?? parsed["author_display_name"] ?? parsed["author"] ?? ""
        let platform = parsed["platform"] ?? inferPlatform(from: folderURL, vaultURL: vaultURL)
        let sourceURL = parsed["url"]     ?? ""

        let body = transcriptSnippet(text, maxChars: 1200)

        let attributes = CSSearchableItemAttributeSet(contentType: UTType.movie)
        attributes.title = title
        attributes.contentDescription = [channel, body]
            .filter { !$0.isEmpty }
            .joined(separator: " — ")
        attributes.keywords = [platform, channel, "youty", "vault"].filter { !$0.isEmpty }
        if !sourceURL.isEmpty, let url = URL(string: sourceURL) {
            attributes.contentURL = url
        }

        let relative = folderURL.path.replacingOccurrences(of: vaultURL.path + "/", with: "")
        let item = CSSearchableItem(
            uniqueIdentifier: "\(platform):\(videoID)",
            domainIdentifier: domainIdentifier,
            attributeSet: attributes
        )
        // Store the relative folder path on the item so the URL-scheme
        // handler can reveal it in Finder later.
        attributes.relatedUniqueIdentifier = relative

        CSSearchableIndex.default().indexSearchableItems([item]) { error in
            if let error = error {
                NSLog("[youty] spotlight index failed: \(error.localizedDescription)")
            }
        }
    }

    /// Drop a video from the Spotlight index — used when its bundle is
    /// deleted or when reconciliation finds an orphan.
    static func deleteBundle(videoID: String, platform: String) {
        CSSearchableIndex.default().deleteSearchableItems(
            withIdentifiers: ["\(platform):\(videoID)"]
        ) { error in
            if let error = error {
                NSLog("[youty] spotlight delete failed: \(error.localizedDescription)")
            }
        }
    }

    /// Drop everything in our Spotlight domain. Useful for a clean rebuild
    /// after the user moves to a new vault.
    static func resetDomain() {
        CSSearchableIndex.default().deleteSearchableItems(
            withDomainIdentifiers: [domainIdentifier]
        ) { error in
            if let error = error {
                NSLog("[youty] spotlight reset failed: \(error.localizedDescription)")
            }
        }
    }

    /// Reconcile Spotlight with the current vault contents. Re-indexes
    /// every bundle in manifest.json. Called on app launch (deferred so
    /// it doesn't block UI) so a vault opened on a new Mac is searchable
    /// without requiring a fresh save first.
    static func reconcileAll() {
        guard let vault = VaultLocalSearch.vaultRootURL() else { return }
        let acquired = vault.startAccessingSecurityScopedResource()
        defer { if acquired { vault.stopAccessingSecurityScopedResource() } }

        // Use the manifest as truth — it's already loaded by every Phase B
        // save.
        let manifestURL = vault.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let entries = try? JSONDecoder().decode([VaultManager.ManifestEntry].self, from: data) else {
            return
        }

        var items: [CSSearchableItem] = []
        for entry in entries {
            let folderURL = vault.appendingPathComponent(entry.folder)
            let noteURL = folderURL.appendingPathComponent("video.md")
            let text = (try? String(contentsOf: noteURL, encoding: .utf8)) ?? ""
            let body = transcriptSnippet(text, maxChars: 1200)

            let attributes = CSSearchableItemAttributeSet(contentType: UTType.movie)
            attributes.title = entry.title
            attributes.contentDescription = [entry.channel, body]
                .filter { !$0.isEmpty }
                .joined(separator: " — ")
            attributes.keywords = [entry.platform, entry.channel, "youty", "vault"]
                .filter { !$0.isEmpty }
            if let url = URL(string: entry.url) {
                attributes.contentURL = url
            }
            attributes.relatedUniqueIdentifier = entry.folder

            let item = CSSearchableItem(
                uniqueIdentifier: "\(entry.platform):\(entry.videoID)",
                domainIdentifier: domainIdentifier,
                attributeSet: attributes
            )
            items.append(item)
        }
        if items.isEmpty {
            NSLog("[youty] spotlight reconcile: no bundles found")
            return
        }
        CSSearchableIndex.default().indexSearchableItems(items) { error in
            if let error = error {
                NSLog("[youty] spotlight reconcile failed: \(error.localizedDescription)")
            } else {
                NSLog("[youty] spotlight reconciled %d bundles", items.count)
            }
        }
    }

    /// Spotlight result click handler. Resolves "platform:videoID" against
    /// the current manifest to find the relative folder, then reveals it.
    static func revealBundle(forIdentifier identifier: String) {
        guard let vault = VaultLocalSearch.vaultRootURL() else { return }
        let acquired = vault.startAccessingSecurityScopedResource()
        defer { if acquired { vault.stopAccessingSecurityScopedResource() } }
        let manifestURL = vault.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let entries = try? JSONDecoder().decode([VaultManager.ManifestEntry].self, from: data) else {
            return
        }
        // Identifier shape: "<platform>:<videoID>".
        let parts = identifier.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        let platform = parts[0]
        let videoID = parts[1]
        guard let match = entries.first(where: { $0.platform == platform && $0.videoID == videoID }) else {
            return
        }
        revealBundle(relativePath: match.folder)
    }

    /// Handler for `youty://open?folder=relative/path`. Resolves the path
    /// against the current vault and opens Finder pointing at it.
    static func revealBundle(relativePath: String) {
        guard let vault = VaultLocalSearch.vaultRootURL() else {
            NSSound.beep()
            return
        }
        let acquired = vault.startAccessingSecurityScopedResource()
        defer { if acquired { vault.stopAccessingSecurityScopedResource() } }
        let folder = vault.appendingPathComponent(relativePath)
        if FileManager.default.fileExists(atPath: folder.path) {
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        } else {
            NSSound.beep()
        }
    }

    // MARK: - Helpers

    private static func parseFrontmatter(_ text: String) -> [String: String] {
        guard text.hasPrefix("---") else { return [:] }
        let lines = text.components(separatedBy: "\n")
        guard let close = lines.dropFirst().firstIndex(of: "---") else { return [:] }
        var kv: [String: String] = [:]
        for line in lines[1..<close] {
            let parts = line.split(separator: ":", maxSplits: 1)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            kv[parts[0]] = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return kv
    }

    private static func transcriptSnippet(_ text: String, maxChars: Int) -> String {
        guard text.hasPrefix("---") else { return String(text.prefix(maxChars)) }
        let lines = text.components(separatedBy: "\n")
        guard let close = lines.dropFirst().firstIndex(of: "---") else { return String(text.prefix(maxChars)) }
        let body = lines.suffix(from: close + 1).joined(separator: " ")
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(maxChars))
    }

    private static func inferPlatform(from folder: URL, vaultURL: URL) -> String {
        let relative = folder.path.replacingOccurrences(of: vaultURL.path + "/", with: "")
        let first = relative.split(separator: "/").first.map(String.init) ?? ""
        switch first {
        case "youtube", "instagram", "tiktok": return first
        default: return "youtube"
        }
    }
}
