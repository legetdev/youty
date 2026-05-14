import Foundation

// `youty transcript <url-or-id>` — print a saved video's transcript.
//
// Resolves the identifier (full URL, or platform-qualified id like
// `yt:abc`, `tt:7234…`, `ig:DEF…`) against manifest.json, then reads
// the matching bundle's `video.md` and prints the body (frontmatter
// stripped). `--json` wraps it in `{"title": ..., "text": ...}`.

enum TranscriptCommand {

    static func run(_ args: ParsedArgs) -> Never {
        guard let identifier = args.positionals.first, !identifier.isEmpty else {
            cliStderr("error: missing url or id.\nusage: youty transcript <url-or-id> [options]\n")
            exit(64)
        }
        guard let vaultResolution = VaultResolver.resolve(flagValue: args.value(for: "vault")) else {
            cliStderr(VaultResolver.noVaultMessage + "\n")
            exit(78)
        }
        let asJSON = args.bool("json")

        let entries = MainActor.assumeIsolated {
            ListReader.entries(vaultURL: vaultResolution.url)
        }
        guard let match = resolve(identifier: identifier, in: entries) else {
            cliStderr("error: no saved video matched '\(identifier)'.\n")
            exit(1)
        }
        let folder = vaultResolution.url.appendingPathComponent(match.folder)
        let noteURL = folder.appendingPathComponent("video.md")
        guard let text = try? String(contentsOf: noteURL, encoding: .utf8) else {
            cliStderr("error: bundle for '\(identifier)' is missing video.md (folder: \(match.folder)).\n")
            exit(1)
        }
        let body = stripFrontmatter(text)

        if asJSON {
            let payload: [String: Any] = [
                "title":    match.title,
                "video_id": match.videoID,
                "platform": match.platform,
                "url":      match.url,
                "folder":   match.folder,
                "text":     body,
            ]
            if let data = try? JSONSerialization.data(
                withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]
            ),
               let str = String(data: data, encoding: .utf8) {
                print(str)
            }
        } else {
            print(body)
        }
        exit(0)
    }

    // MARK: - Helpers

    private static func resolve(identifier raw: String,
                                in entries: [VaultManager.ManifestEntry])
                                -> VaultManager.ManifestEntry? {
        let needle = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return nil }
        return entries.first { entry in
            if entry.url.lowercased() == needle { return true }
            if needle.contains(entry.videoID.lowercased()) { return true }
            let qualified = "\(prefix(entry.platform)):\(entry.videoID)".lowercased()
            return needle == qualified || needle.hasSuffix(qualified)
        }
    }

    private static func prefix(_ platform: String) -> String {
        switch platform {
        case "instagram": return "ig"
        case "tiktok":    return "tt"
        default:          return "yt"
        }
    }

    private static func stripFrontmatter(_ text: String) -> String {
        guard text.hasPrefix("---") else { return text }
        let lines = text.components(separatedBy: "\n")
        guard let close = lines.dropFirst().firstIndex(of: "---") else { return text }
        return lines.suffix(from: close + 1)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
