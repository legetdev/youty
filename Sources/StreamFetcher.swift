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

    // All resolutions the fast path knows how to handle, expressed as the
    // long-edge pixel count parsed from qualityLabel ("1080p", "1080p60",
    // "1080p HFR" all bucket as 1080). Used to filter candidates down to
    // recognisable rungs before applying the target-based priority ordering.
    static let knownHeights: [Int] = [144, 240, 360, 480, 720, 1080, 1440, 2160]

    /// Default fallback when no explicit target is supplied (legacy callers).
    static let defaultTargetResolution: Int = 1080

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
    /// Selects the best fast-path stream for a target resolution.
    ///
    /// Priority order:
    ///   1. Exact match at `targetResolution`.
    ///   2. Highest available below `targetResolution`. Never picks a lower
    ///      rung when a higher rung at-or-below the target was available — so
    ///      a user targeting 1440p with `{720, 1080}` available gets 1080p,
    ///      not 720p.
    ///   3. Lowest available above `targetResolution`. Only reached when the
    ///      source ladder starts above the target (e.g. target 720p, only
    ///      1080p+ available). Edge case; logged explicitly.
    ///
    /// Within a chosen rung the legacy preferences still apply: non-HFR over
    /// HFR, then H.264 → VP9 → AV1.
    static func selectFastPathStream(from formats: [[String: Any]],
                                     progressiveCount: Int,
                                     targetResolution: Int = defaultTargetResolution) throws -> VideoStream {
        guard formats.count >= progressiveCount else { throw StreamFetchError.noFastPathAvailable }

        // True video length = longest approxDurationMs across all formats.
        let maxDurMs = formats.compactMap { $0["approxDurationMs"] as? Int }.max() ?? 0

        // FFmpeg handles every codec YouTube ships — H.264, VP9, AV1 — so we
        // don't filter by codec, only by resolution. Within a resolution
        // bucket: H.264 (hardware-decoded everywhere) > VP9 (Apple-Silicon HW
        // only) > AV1 (M3+ HW only, software elsewhere).
        let codecPriority: [(String, String)] = [
            ("H264", "avc1"), ("VP9", "vp9"), ("AV1", "av01"),
        ]
        let candidates = formats.filter { f in
            guard let mime = f["mimeType"] as? String,
                  let urlStr = f["url"] as? String, !urlStr.isEmpty,
                  f["qualityLabel"] != nil else { return false }
            if !codecPriority.contains(where: { mime.contains($0.1) }) { return false }
            if maxDurMs > 0,
               let durMs = f["approxDurationMs"] as? Int,
               Double(durMs) < 0.9 * Double(maxDurMs) {
                return false
            }
            // Only consider rungs the priority list knows. Anything else
            // (oddball labels) gets ignored — better than silently picking
            // an unrecognised bucket.
            let q = (f["qualityLabel"] as? String) ?? ""
            return knownHeights.contains(parsedHeight(of: q))
        }
        guard !candidates.isEmpty else { throw StreamFetchError.noFastPathAvailable }

        // Diagnostic: log every candidate's qualityLabel + codec.
        let summary = candidates.prefix(20).compactMap { c -> String? in
            let q = (c["qualityLabel"] as? String) ?? "?"
            let m = (c["mimeType"] as? String) ?? "?"
            let codec = m.contains("avc1") ? "H264" : m.contains("vp9") ? "VP9" : m.contains("av01") ? "AV1" : "?"
            return "\(q)/\(codec)"
        }.joined(separator: " ")
        DebugLog.log("stream-select: target=\(targetResolution)p candidates=\(candidates.count) [\(summary)]")

        // Distinct heights actually present in this video's ladder.
        let availableHeights: Set<Int> = Set(candidates.compactMap { c in
            guard let q = c["qualityLabel"] as? String else { return nil }
            let h = parsedHeight(of: q)
            return h > 0 ? h : nil
        })
        DebugLog.log("stream-select: target=\(targetResolution)p available_heights=\(availableHeights.sorted())")

        // Build the priority order:
        //   exact target → highest below (descending) → lowest above (ascending).
        // This is the canonical "pick best at-or-below target, fall back up
        // only if nothing at-or-below exists" ordering.
        var priority: [Int] = []
        if availableHeights.contains(targetResolution) {
            priority.append(targetResolution)
        }
        priority.append(contentsOf: availableHeights.filter { $0 < targetResolution }.sorted(by: >))
        priority.append(contentsOf: availableHeights.filter { $0 > targetResolution }.sorted())
        DebugLog.log("stream-select: target=\(targetResolution)p priority=\(priority)")

        for height in priority {
            for hfrPreference in [false, true] {
                for (codecName, mimeMarker) in codecPriority {
                    if let f = candidates.first(where: { c in
                        guard let q = c["qualityLabel"] as? String,
                              let m = c["mimeType"] as? String,
                              parsedHeight(of: q) == height else { return false }
                        let isHfr = q.contains("60") || q.contains("HFR")
                        return isHfr == hfrPreference && m.contains(mimeMarker)
                    }) {
                        let label = (f["qualityLabel"] as? String) ?? "?"
                        let relation: String
                        if height == targetResolution { relation = "exact" }
                        else if height < targetResolution { relation = "below(highest-at-or-below)" }
                        else { relation = "above(lowest-above)" }
                        DebugLog.log("stream-select: target=\(targetResolution)p PICKED \(label) / \(codecName) (\(relation))")
                        return try makeStream(from: f, codec: codecName)
                    }
                }
            }
        }
        // Defensive: if the priority loop didn't pick anything (shouldn't
        // happen because every height in availableHeights came from a real
        // candidate), fall back to the first candidate.
        DebugLog.log("stream-select: target=\(targetResolution)p NO PRIORITY MATCH — falling back to first candidate")
        return try makeStream(from: candidates[0], codec: "H264")
    }

    // Extracts the long-edge height from a YouTube qualityLabel like "1080p",
    // "1080p60", or "1080p HFR". Returns 0 if no digits are found.
    private static func parsedHeight(of label: String) -> Int {
        var digits = ""
        for ch in label {
            if ch.isNumber { digits.append(ch) }
            else if !digits.isEmpty { break }
        }
        return Int(digits) ?? 0
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
