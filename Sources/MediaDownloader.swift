import Foundation

// Downloads a remote video URL to a local temp file so it can be opened by
// AVFoundation (frame extraction + audio transcription). Used by the
// Instagram + TikTok flows.
//
// Why download once instead of byte-range streaming:
//   Instagram + TikTok serve typical short-form videos at 5-30 MB. A single
//   sequential download from their CDNs completes in 1-3 s on a normal
//   connection. After that, AVAssetImageGenerator + AVAudioFile work
//   instantly on the local file — fast, native, no FFmpeg muxer required.
//   YouTube's hour-long 100+ MB streams justified the byte-range pipeline;
//   30-second Reels do not.
//
// Sandbox-compatible. Temp files live in NSTemporaryDirectory() (the app's
// container) and are removed by the caller when done.

enum MediaDownloaderError: LocalizedError {
    case badResponse(Int)
    case empty
    case underlying(Error)
    var errorDescription: String? {
        switch self {
        case .badResponse:
            return "Couldn't download the video — the server refused or returned an error. Try a different post."
        case .empty:
            return "The video download was empty. Try a different post."
        case .underlying(let e):
            return "Couldn't download the video: \(e.localizedDescription)"
        }
    }
}

enum MediaDownloader {

    /// Downloads `url` to a temp file. `headers` may include any HTTP headers
    /// needed to satisfy the CDN — TikTok requires Sec-Fetch-* + Origin +
    /// Range; Instagram requires User-Agent matching the session. Pass an
    /// empty dict if none are needed.
    /// Optional `progress` callback fires with 0..1 fraction as bytes arrive.
    /// Returns the file URL of the downloaded payload; caller must clean it up.
    static func download(
        url: URL,
        headers: [String: String] = [:],
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {

        var req = URLRequest(url: url)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.timeoutInterval = 30

        // Use URLSession.shared. Verified empirically (2026-05-12) that
        // TikTok's CDN returns 403 to requests issued from a custom
        // URLSessionConfiguration.ephemeral session even with identical
        // headers — the WAF must be fingerprinting some default Accept-
        // Encoding / TLS-feature-set behavior that .shared has but .ephemeral
        // doesn't. Using .shared is the lowest-friction reliable path.
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { throw MediaDownloaderError.badResponse(0) }
            guard (200..<300).contains(http.statusCode) else {
                throw MediaDownloaderError.badResponse(http.statusCode)
            }
            guard !data.isEmpty else { throw MediaDownloaderError.empty }

            let tempPath = NSTemporaryDirectory()
                .appending("youty-media-")
                .appending(UUID().uuidString)
                .appending(".mp4")
            let outURL = URL(fileURLWithPath: tempPath)
            try data.write(to: outURL)
            progress?(1.0)
            return outURL
        } catch let e as MediaDownloaderError {
            throw e
        } catch {
            throw MediaDownloaderError.underlying(error)
        }
    }

    /// Best-effort cleanup of a temp file. Safe to call on a missing path.
    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
