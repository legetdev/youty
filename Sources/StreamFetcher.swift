import Foundation

// Fetches H.264 720p+ stream URLs via the ANDROID_VR InnerTube client.
//
// Why ANDROID_VR (clientName 28, version 1.65.10):
//   ANDROID_VR returns plain signed MP4 URLs (no n-decoder, no signature cipher).
//   The URLs accept arbitrary byte-range requests, unlike the regular ANDROID
//   client which silently caps at ~1.5 MB total per URL. This is what makes
//   16-way parallel downloading viable.
//
// Visitor data caching:
//   Stored in UserDefaults with a 7-day TTL. First-run cost is ~250 ms; every
//   subsequent extraction skips the homepage GET. Invalidated on 401/403.

struct VideoStream {
    let url: URL
    let quality: String      // "720p", "1080p", "1440p", "2160p"
    let codec: String        // "H264" only for fast path
    let contentLength: Int   // total bytes — required for parallel download
    let mimeType: String
}

enum StreamFetchError: LocalizedError {
    case noFastPathAvailable           // no H.264 720p+ stream
    case restrictedVideo               // playabilityStatus != "OK"
    case visitorDataInvalid            // 401/403 — caller should refresh and retry
    case networkError(Int)             // HTTP error from InnerTube call
    case parseError                    // malformed JSON response

    var errorDescription: String? {
        switch self {
        case .noFastPathAvailable: return "No H.264 720p+ stream available."
        case .restrictedVideo:     return "Video is restricted or unavailable."
        case .visitorDataInvalid:  return "YouTube session expired."
        case .networkError(let c): return "YouTube returned HTTP \(c)."
        case .parseError:          return "Could not parse YouTube response."
        }
    }
}

enum StreamFetcher {

    // MARK: - Constants

    private static let webUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
    static let androidVRUA = "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip"

    // Fast-path quality ladder. 720p is preferred — it's typically 3–4× smaller
    // than 1080p, downloads in seconds rather than tens of seconds, and is
    // visually identical for AI frame analysis. We fall up to higher resolutions
    // only when 720p isn't available for this video.
    static let fastPathQualities = ["720p", "1080p", "1440p", "2160p"]

    // MARK: - Visitor data caching

    private static let cacheKey = "youtubeVisitorData"
    private static let cacheTimestampKey = "youtubeVisitorDataTimestamp"
    private static let maxCacheAge: TimeInterval = 7 * 24 * 3600

    static func cachedVisitorData() -> String? {
        guard let stored = UserDefaults.standard.string(forKey: cacheKey),
              !stored.isEmpty,
              let ts = UserDefaults.standard.object(forKey: cacheTimestampKey) as? Date,
              Date().timeIntervalSince(ts) < maxCacheAge else { return nil }
        return stored
    }

    static func cacheVisitorData(_ value: String) {
        UserDefaults.standard.set(value, forKey: cacheKey)
        UserDefaults.standard.set(Date(), forKey: cacheTimestampKey)
    }

    static func invalidateVisitorData() {
        UserDefaults.standard.removeObject(forKey: cacheKey)
        UserDefaults.standard.removeObject(forKey: cacheTimestampKey)
    }

    // Returns cached value when fresh; otherwise scrapes the homepage.
    static func getVisitorData() async throws -> String {
        if let cached = cachedVisitorData() { return cached }
        let fresh = try await fetchVisitorData()
        cacheVisitorData(fresh)
        return fresh
    }

    private static func fetchVisitorData() async throws -> String {
        var req = URLRequest(url: URL(string: "https://www.youtube.com/")!)
        req.setValue(webUA, forHTTPHeaderField: "User-Agent")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        let (data, _) = try await URLSession.shared.data(for: req)
        let html = String(data: data, encoding: .utf8) ?? ""
        if let range = html.range(of: "\"VISITOR_DATA\":\""),
           let end = html[range.upperBound...].firstIndex(of: "\"") {
            return String(html[range.upperBound..<end])
        }
        return ""  // empty visitor data still works for most videos
    }

    // MARK: - InnerTube format fetch

    static func fetchFormats(videoID: String,
                             visitorData: String) async throws -> [[String: Any]] {
        var req = URLRequest(url: URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(androidVRUA,         forHTTPHeaderField: "User-Agent")
        req.setValue("28",                forHTTPHeaderField: "X-YouTube-Client-Name")
        req.setValue("1.65.10",           forHTTPHeaderField: "X-YouTube-Client-Version")
        if !visitorData.isEmpty {
            req.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id")
        }

        let body: [String: Any] = [
            "context": [
                "client": [
                    "clientName": "ANDROID_VR",
                    "clientVersion": "1.65.10",
                    "androidSdkVersion": 32,
                    "deviceMake": "Oculus",
                    "deviceModel": "Quest 3",
                    "osName": "Android",
                    "osVersion": "12L",
                    "userAgent": androidVRUA,
                    "hl": "en",
                    "gl": "US",
                    "visitorData": visitorData
                ]
            ],
            "videoId": videoID,
            "racyCheckOk": true,
            "contentCheckOk": true
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw StreamFetchError.visitorDataInvalid }
        guard status == 200 else { throw StreamFetchError.networkError(status) }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StreamFetchError.parseError
        }

        let playability = (json["playabilityStatus"] as? [String: Any])?["status"] as? String ?? ""
        guard playability == "OK" else { throw StreamFetchError.restrictedVideo }

        return (json["streamingData"] as? [String: Any])?["adaptiveFormats"] as? [[String: Any]] ?? []
    }

    // MARK: - Format selection

    // Selects an H.264 720p+ stream, preferring 720p for smallest file size.
    // Why H.264-only: AVFoundation's hardware AV01 decoder doesn't exist on Intel Macs;
    //                 H.264 is universally decodable.
    // Why 720p+ only: at 480p, H.264 DASH keyframes are every ~20s, which limits
    //                 AVAssetImageGenerator to ~50 frames per video.
    // Why 720p preferred: ~3–4× smaller than 1080p, downloads in 1/3 the time,
    //                     visually identical for AI frame analysis.
    static func selectFastPathStream(from formats: [[String: Any]]) throws -> VideoStream {
        let h264 = formats.filter { f in
            guard let mime = f["mimeType"] as? String,
                  let urlStr = f["url"] as? String, !urlStr.isEmpty,
                  f["qualityLabel"] != nil,
                  f["contentLength"] != nil else { return false }
            return mime.contains("video/mp4") && mime.contains("avc1")
        }
        guard !h264.isEmpty else { throw StreamFetchError.noFastPathAvailable }

        // Try 720p first; fall up only if 720p isn't available for this video.
        for quality in fastPathQualities {
            if let f = h264.first(where: { ($0["qualityLabel"] as? String) == quality }) {
                return try makeStream(from: f)
            }
        }
        throw StreamFetchError.noFastPathAvailable
    }

    private static func makeStream(from f: [String: Any]) throws -> VideoStream {
        guard let urlStr = f["url"] as? String, let streamURL = URL(string: urlStr) else {
            throw StreamFetchError.parseError
        }
        let mime   = f["mimeType"] as? String ?? ""
        let quality = f["qualityLabel"] as? String ?? "720p"
        let length = Int(f["contentLength"] as? String ?? "0") ?? 0
        guard length > 0 else { throw StreamFetchError.parseError }
        return VideoStream(url: streamURL, quality: quality, codec: "H264",
                           contentLength: length, mimeType: mime)
    }
}
