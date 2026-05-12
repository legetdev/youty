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
        let s = urlString.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if isYouTube(s) { return .youtube }
        if isTikTok(s)  { return .tiktok }
        if isInstagram(s) { return .instagram }
        return nil
    }

    private static func isYouTube(_ s: String) -> Bool {
        return s.contains("youtube.com/") || s.contains("youtu.be/") || s.contains("youtube.com/shorts/")
    }

    private static func isTikTok(_ s: String) -> Bool {
        return s.contains("tiktok.com/") || s.contains("vm.tiktok.com/")
    }

    private static func isInstagram(_ s: String) -> Bool {
        return s.contains("instagram.com/reel/")
            || s.contains("instagram.com/p/")
            || s.contains("instagram.com/tv/")
            || s.contains("instagram.com/reels/")
    }
}
