import Foundation

// `youty search <query>` — keyword search.
//
// Token-AND match against title + channel + tags + platform from
// manifest.json. Ranked by token-prefix-weight; ties broken by recency.
// Sub-millisecond on a 10K-video vault — no embedder, no SQLite.

enum SearchCommand {

    static func run(_ args: ParsedArgs) -> Never {
        guard let query = args.positionals.first, !query.isEmpty else {
            cliStderr("error: missing search query.\nusage: youty search <query> [options]\n")
            exit(64)
        }
        guard let vaultResolution = VaultResolver.resolve(flagValue: args.value(for: "vault")) else {
            cliStderr(VaultResolver.noVaultMessage + "\n")
            exit(78)
        }
        let limit = args.intValue(for: "limit") ?? 10
        let asText = args.bool("text")

        let entries = MainActor.assumeIsolated {
            ListReader.entries(vaultURL: vaultResolution.url)
        }
        let matches = filter(entries: entries, query: query, limit: limit)

        if asText {
            emitText(matches)
        } else {
            emitJSON(matches)
        }
        exit(0)
    }

    // MARK: - Filter

    private static func filter(entries: [VaultManager.ManifestEntry],
                               query: String,
                               limit: Int) -> [VaultManager.ManifestEntry] {
        let tokens = tokenize(query)
        guard !tokens.isEmpty else { return [] }

        var scored: [(VaultManager.ManifestEntry, Int)] = []
        for entry in entries {
            let haystack = ([entry.title, entry.channel]
                            + entry.tags
                            + [entry.platform])
                .joined(separator: " ")
                .lowercased()
            var matchedAll = true
            var score = 0
            for tok in tokens {
                if haystack.contains(tok) {
                    score += haystack.contains(" " + tok) || haystack.hasPrefix(tok) ? 2 : 1
                } else {
                    matchedAll = false
                    break
                }
            }
            if matchedAll {
                scored.append((entry, score))
            }
        }
        let sorted = scored.sorted { a, b in
            if a.1 != b.1 { return a.1 > b.1 }
            return a.0.dateSaved > b.0.dateSaved
        }
        return Array(sorted.prefix(limit).map { $0.0 })
    }

    private static func tokenize(_ s: String) -> [String] {
        s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
    }

    // MARK: - Output

    private static func emitText(_ entries: [VaultManager.ManifestEntry]) {
        if entries.isEmpty {
            cliStderr("No matches.\n")
            return
        }
        for entry in entries {
            let channel = entry.channel.isEmpty ? entry.platform : entry.channel
            print("\(entry.title)")
            print("  \(channel) · \(entry.platform) · \(entry.folder)")
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
                "date_saved": e.dateSaved,
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
