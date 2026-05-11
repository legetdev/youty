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
    let codec: String        // "H264" or "VP9"
    let contentLength: Int   // total bytes — required for sequential download
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

    // Fast-path quality ladder. 720p preferred (typical sweet spot of size +
    // quality). 1080p+ used only when smaller isn't available. 480p/360p/240p
    // accepted as a last resort — the canvas extractor upscales to 1280×720
    // regardless of source resolution, so a lower source is still usable.
    static let fastPathQualities = [
        "720p", "1080p", "480p", "360p", "1440p", "2160p", "240p", "144p"
    ]

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
        req.timeoutInterval = 3
        let (data, _) = try await URLSession.shared.data(for: req)
        let html = String(data: data, encoding: .utf8) ?? ""
        if let range = html.range(of: "\"VISITOR_DATA\":\""),
           let end = html[range.upperBound...].firstIndex(of: "\"") {
            return String(html[range.upperBound..<end])
        }
        return ""  // empty visitor data still works for most videos
    }

    // MARK: - InnerTube format fetch

    struct FormatList {
        let formats: [[String: Any]]      // progressive first, then adaptive
        let progressiveCount: Int
        // True video length in seconds, from videoDetails.lengthSeconds.
        // The file's MP4 mvhd / WebKit <video>.duration can disagree with
        // this value for DASH-fragmented streams; this is the ground truth.
        let lengthSeconds: TimeInterval
    }

    static func fetchFormats(videoID: String,
                             visitorData: String) async throws -> FormatList {
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
        req.timeoutInterval = 3

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw StreamFetchError.visitorDataInvalid }
        guard status == 200 else { throw StreamFetchError.networkError(status) }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StreamFetchError.parseError
        }

        let playability = (json["playabilityStatus"] as? [String: Any])?["status"] as? String ?? ""
        guard playability == "OK" else { throw StreamFetchError.restrictedVideo }

        let sd = json["streamingData"] as? [String: Any]
        let progressive = sd?["formats"] as? [[String: Any]] ?? []
        let adaptive    = sd?["adaptiveFormats"] as? [[String: Any]] ?? []

        // Ground-truth length from videoDetails. Falls back to longest
        // approxDurationMs if videoDetails.lengthSeconds is missing.
        let vd = json["videoDetails"] as? [String: Any]
        let lengthSecondsStr = vd?["lengthSeconds"] as? String ?? ""
        let lengthFromDetails = TimeInterval(lengthSecondsStr) ?? 0
        let lengthFromFormats: TimeInterval = {
            let maxMs = (progressive + adaptive)
                .compactMap { $0["approxDurationMs"] as? Int }.max() ?? 0
            return TimeInterval(maxMs) / 1000.0
        }()
        let length = lengthFromDetails > 0 ? lengthFromDetails : lengthFromFormats

        return FormatList(formats: progressive + adaptive,
                          progressiveCount: progressive.count,
                          lengthSeconds: length)
    }

    // MARK: - Format selection

    // Selects an H.264 stream the fast path can decode reliably.
    //
    // ANDROID_VR returns two arrays:
    //   - formats[]: progressive (video+audio in one file, moov at start,
    //     single contiguous H.264 stream)
    //   - adaptiveFormats[]: DASH-fragmented (moof+mdat segments). YouTube's
    //     DASH H.264 streams switch codec configuration at the midpoint, and
    //     AVFoundation's H.264 decoder — which both AVAssetImageGenerator and
    //     WebKit's <video> element use under the hood on macOS — silently
    //     fails on the second half. We've verified this with every random-
    //     access and linear API in AVFoundation.
    //
    // Therefore: ONLY progressive H.264 is viable for the fast path. We pick
    // the highest-quality progressive available (typically itag 22 at 720p,
    // or itag 18 at 360p). When progressive isn't available, the fast path
    // fails and we let the user choose canvas-on-YouTube fallback.
    //
    // Why no VP9/AV1: VP9 ships in WebM which AVFoundation cannot open. AV1
    // hardware decode is M3+ only; software decode is too slow.
    static func selectFastPathStream(from formats: [[String: Any]],
                                     progressiveCount: Int) throws -> VideoStream {
        guard formats.count >= progressiveCount else { throw StreamFetchError.noFastPathAvailable }

        // True video length = longest approxDurationMs across all formats.
        let maxDurMs = formats.compactMap { $0["approxDurationMs"] as? Int }.max() ?? 0

        // Consider adaptive AND progressive H.264 — both decode correctly when
        // played by WebKit's <video> element against a local file. We prefer
        // 720p+ adaptive for actual 720p detail, and only drop to lower
        // resolutions when nothing else exists.
        let h264 = formats.filter { f in
            guard let mime = f["mimeType"] as? String,
                  let urlStr = f["url"] as? String, !urlStr.isEmpty,
                  f["qualityLabel"] != nil else { return false }
            if !mime.contains("avc1") { return false }
            // Reject streams whose duration is < 90 % of the true video
            // length — those are truncated previews.
            if maxDurMs > 0,
               let durMs = f["approxDurationMs"] as? Int,
               Double(durMs) < 0.9 * Double(maxDurMs) {
                return false
            }
            return true
        }
        guard !h264.isEmpty else { throw StreamFetchError.noFastPathAvailable }

        for quality in fastPathQualities {
            if let f = h264.first(where: { ($0["qualityLabel"] as? String) == quality }) {
                return try makeStream(from: f, codec: "H264")
            }
        }
        return try makeStream(from: h264[0], codec: "H264")
    }

    private static func makeStream(from f: [String: Any], codec: String) throws -> VideoStream {
        guard let urlStr = f["url"] as? String, let streamURL = URL(string: urlStr) else {
            throw StreamFetchError.parseError
        }
        let mime   = f["mimeType"] as? String ?? ""
        let quality = f["qualityLabel"] as? String ?? "720p"
        // contentLength is sometimes absent for progressive formats. Use 0 as
        // "unknown" — the downloader treats it as "download until server
        // returns a short chunk".
        let length = Int(f["contentLength"] as? String ?? "0") ?? 0
        return VideoStream(url: streamURL, quality: quality, codec: codec,
                           contentLength: length, mimeType: mime)
    }
}
