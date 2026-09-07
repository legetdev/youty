import Foundation

// Maps a pasted URL to the platform whose extractor should handle it.
// Centralised so future platforms only need a one-line table entry.

enum Platform: String, Sendable {
    case youtube
    case tiktok
    case instagram
}

enum PlatformRouter {

    /// Returns the platform for a pasted URL string, or `nil` if the string
    /// doesn't resemble any known platform's post URL.
    static func platform(for urlString: String) -> Platform? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: normalized),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(), url.user == nil, url.password == nil else { return nil }
        if host == "youtube.com" || host.hasSuffix(".youtube.com")
            || host == "youtu.be" { return .youtube }
        if host == "tiktok.com" || host.hasSuffix(".tiktok.com") { return .tiktok }
        if host == "instagram.com" || host.hasSuffix(".instagram.com") {
            let path = url.pathComponents.filter { $0 != "/" }
            if path.count >= 2, ["reel", "reels", "p", "tv"].contains(path[0]) { return .instagram }
        }
        return nil
    }
}
