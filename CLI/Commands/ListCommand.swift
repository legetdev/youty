import Foundation

// `youty list` — list saved videos.
//
// Reads `manifest.json` at the vault root. No network, no WKWebView, no
// extraction — instant. Filters optionally by --platform. JSON output
// by default (per spec: list/search/transcript pipe nicely). --text for
// a human-readable summary.

enum ListCommand {

    static func run(_ args: ParsedArgs) -> Never {
        guard let vaultResolution = VaultResolver.resolve(flagValue: args.value(for: "vault")) else {
            cliStderr(VaultResolver.noVaultMessage + "\n")
            exit(78)
        }
        let platformFilter = args.value(for: "platform")?.lowercased()
        let limit = args.intValue(for: "limit")
        let asText = args.bool("text")

        let result = MainActor.assumeIsolated { () -> [VaultManager.ManifestEntry] in
            // VaultLocalSearch's manifest reader is the canonical one; reuse it.
            let entries = ListReader.entries(vaultURL: vaultResolution.url)
            let filtered = platformFilter.map { p in
                entries.filter { $0.platform == p }
            } ?? entries
            let sorted = filtered.sorted { $0.dateSaved > $1.dateSaved }
            return limit.map { Array(sorted.prefix($0)) } ?? sorted
        }

        if asText {
            emitText(result)
        } else {
            emitJSON(result)
        }
        exit(0)
    }

    private static func emitText(_ entries: [VaultManager.ManifestEntry]) {
        if entries.isEmpty {
            cliStderr("No saved videos.\n")
            return
        }
        for entry in entries {
            let channel = entry.channel.isEmpty ? entry.platform : entry.channel
            print("\(entry.platform.padding(toLength: 9, withPad: " ", startingAt: 0))  \(entry.title)")
            print("           by \(channel) — \(entry.folder)")
        }
    }

    private static func emitJSON(_ entries: [VaultManager.ManifestEntry]) {
        let payload: [[String: Any]] = entries.map { e in
            return [
                "video_id":   e.videoID,
                "title":      e.title,
                "channel":    e.channel,
                "platform":   e.platform,
                "folder":     e.folder,
                "url":        e.url,
                "duration":   e.duration,
                "date_saved": e.dateSaved,
                "tags":       e.tags,
            ]
        }
        if let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]
        ),
           let str = String(data: data, encoding: .utf8) {
            print(str)
        }
    }
}

// Tiny wrapper around manifest reading so List doesn't reach into
// VaultLocalSearch (which exposes UserDefaults-backed bookmark reads
// that wouldn't help us — the CLI already resolved the path).
enum ListReader {

    @MainActor
    static func entries(vaultURL: URL) -> [VaultManager.ManifestEntry] {
        let manifestURL = vaultURL.appendingPathComponent("manifest.json")
        if let data = try? Data(contentsOf: manifestURL),
           let entries = try? JSONDecoder().decode(
               [VaultManager.ManifestEntry].self, from: data
           ) {
            return entries
        }
        // Manifest missing — rebuild from the directory tree, then retry.
        VaultManager.writeManifest(in: vaultURL)
        if let data = try? Data(contentsOf: manifestURL),
           let entries = try? JSONDecoder().decode(
               [VaultManager.ManifestEntry].self, from: data
           ) {
            return entries
        }
        return []
    }
}
