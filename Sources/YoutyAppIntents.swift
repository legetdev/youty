import AppIntents
import Foundation
import AppKit

// AppIntents — three actions that show up in Shortcuts.app, Siri, the
// Spotlight "Actions" surface, and any automation that talks to Apple's
// intents system.
//
//   1. Save URL to Youty Vault   — accepts a URL, queues + opens main app.
//   2. Search Youty Vault         — keyword search over saved videos.
//   3. Get Transcript from Youty  — fetch transcript text by URL/id.
//
// Surfaces are intentionally small and useful — no per-platform variants,
// no setting overrides, no chain-only-callable intents. Each one is
// something a user might genuinely automate ("when I copy a YouTube URL,
// save it"; "every Friday, list videos I saved this week").

// MARK: - 1. Save URL to Youty Vault

struct SaveURLToYoutyVaultIntent: AppIntent {
    static let title: LocalizedStringResource = "Save URL to Youty Vault"
    static let description = IntentDescription(
        "Save a YouTube, Instagram, or TikTok URL to your Youty Vault.",
        categoryName: "Youty",
        searchKeywords: ["youtube", "tiktok", "instagram", "save", "download"]
    )

    // Open the app so the visible save UX runs. Without this, Shortcuts
    // would background-launch and the WKWebView attach would fail.
    static let openAppWhenRun: Bool = true

    @Parameter(title: "URL", description: "A YouTube, Instagram, or TikTok post URL.")
    var url: URL

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let urlString = url.absoluteString
        guard YoutyShareURLClassifier.isSupported(urlString) else {
            throw $url.needsValueError(
                "URL isn't a YouTube, Instagram, or TikTok post."
            )
        }
        IngestionFunnel.shared.ingest(urlString: urlString, source: "intent")
        return .result(value: urlString)
    }
}

// MARK: - 2. Search Youty Vault

struct SearchYoutyVaultIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Youty Vault"
    static let description = IntentDescription(
        "Find saved videos matching a keyword. Returns the top matches by title, channel, and tags.",
        categoryName: "Youty"
    )

    static let openAppWhenRun: Bool = false

    @Parameter(title: "Query", description: "Text to match against titles, channels, and tags.")
    var query: String

    @Parameter(title: "Limit", default: 10, controlStyle: .stepper, inclusiveRange: (1, 50))
    var limit: Int

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[String]> & ProvidesDialog {
        let results = VaultLocalSearch.search(query: query, limit: limit)
        let formatted = results.map { entry in
            "\(entry.title) — \(entry.channel.isEmpty ? entry.platform : entry.channel) (\(entry.url))"
        }
        let dialog: IntentDialog = results.isEmpty
            ? "No saved videos matched \"\(query)\"."
            : IntentDialog("Found \(results.count) saved video\(results.count == 1 ? "" : "s") matching \"\(query)\".")
        return .result(value: formatted, dialog: dialog)
    }
}

// MARK: - 3. Get Transcript from Youty

struct GetYoutyTranscriptIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Transcript from Youty"
    static let description = IntentDescription(
        "Return the transcript of a video already saved to the Youty Vault. Looks up by URL or video ID.",
        categoryName: "Youty"
    )

    static let openAppWhenRun: Bool = false

    @Parameter(title: "Video URL or ID", description: "The URL of a saved post, or its platform-qualified ID (e.g. yt:abc123).")
    var identifier: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let transcript = VaultLocalSearch.transcript(forIdentifier: identifier) else {
            return .result(
                value: "",
                dialog: "No saved video matched \"\(identifier)\"."
            )
        }
        return .result(
            value: transcript.text,
            dialog: IntentDialog("Transcript for \(transcript.title) (\(transcript.text.count) characters).")
        )
    }
}

// MARK: - Shortcuts.app surface

struct YoutyAppShortcuts: AppShortcutsProvider {
    @AppShortcutsBuilder
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SaveURLToYoutyVaultIntent(),
            phrases: [
                "Save \(.applicationName)",
                "Save URL to \(.applicationName)",
                "Add to my \(.applicationName) vault",
            ],
            shortTitle: "Save URL",
            systemImageName: "tray.and.arrow.down"
        )
        AppShortcut(
            intent: SearchYoutyVaultIntent(),
            phrases: [
                "Search \(.applicationName)",
                "Find in \(.applicationName) vault",
            ],
            shortTitle: "Search Vault",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: GetYoutyTranscriptIntent(),
            phrases: [
                "Get transcript from \(.applicationName)",
                "\(.applicationName) transcript",
            ],
            shortTitle: "Get Transcript",
            systemImageName: "doc.text"
        )
    }

    static let shortcutTileColor: ShortcutTileColor = .navy
}

// MARK: - URL classifier reused by AppIntents

enum YoutyShareURLClassifier {
    static func isSupported(_ urlString: String) -> Bool {
        // Mirror PlatformRouter without forcing AppIntents to depend on it.
        let s = urlString.lowercased()
        return s.contains("youtube.com/")
            || s.contains("youtu.be/")
            || s.contains("tiktok.com/")
            || s.contains("vm.tiktok.com/")
            || s.contains("instagram.com/reel/")
            || s.contains("instagram.com/p/")
            || s.contains("instagram.com/tv/")
            || s.contains("instagram.com/reels/")
    }
}
