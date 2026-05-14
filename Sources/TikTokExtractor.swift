import Foundation
import CryptoKit

// TikTok video extractor. Hits the public webapp page anonymously, scrapes
// `__UNIVERSAL_DATA_FOR_REHYDRATION__`, parses the itemStruct hydration
// payload, and returns a structured result with the un-watermarked CDN URL,
// metadata, and pre-existing auto-captions when present.
//
// References (consulted, not depended on):
//   • yt-dlp/yt_dlp/extractor/tiktok.py @ HEAD (web path, _parse_aweme_video_web)
//   • Empirically verified URLSession reaches www.tiktok.com without WAF
//     block (TLS pretest 2026-05-12).
//
// Sandbox-compatible. Pure URLSession + JSONSerialization + CryptoKit.

struct TikTokMetadata: Sendable {
    let videoID: String
    let url: String              // canonical URL we resolved to
    let description: String
    let author: String           // "@username"
    let authorDisplayName: String
    let postedAt: Date?
    let duration: TimeInterval
    let width: Int
    let height: Int
    let likes: Int?
    let comments: Int?
    let shares: Int?
    let plays: Int?
    let saves: Int?
    let musicTitle: String?
    let musicAuthor: String?
    let musicAlbum: String?
    let hashtags: [String]
}

struct TikTokExtractionResult: Sendable {
    let metadata: TikTokMetadata
    /// Signed CDN URL serving the un-watermarked progressive MP4. Short TTL —
    /// fetch immediately.
    let videoCDNURL: URL
    /// HTTP headers required by the CDN. Pass to `MediaDownloader.download`
    /// verbatim — the CDN gates on Sec-Fetch-* + Origin + Range; missing any
    /// of these returns 403.
    let videoDownloadHeaders: [String: String]
    /// Pre-existing auto-captions when TikTok exposes them, else `nil`
    /// (the caller should run SpeechTranscriptionPipeline on the video file
    /// to produce the transcript itself).
    let captions: [TranscriptSegment]?
}

enum TikTokExtractorError: LocalizedError {
    case malformedURL(String)
    case couldNotResolveShortURL
    case pageFetchFailed(Int)
    case noHydration
    case noItemStruct
    case noVideoURL
    case wafChallengeUnsolvable
    case malformedJSON

    var errorDescription: String? {
        switch self {
        case .malformedURL:
            return "That URL doesn't look like a TikTok video. Use a /video/ link from tiktok.com."
        case .couldNotResolveShortURL:
            return "Couldn't expand that TikTok short link. Open the link in TikTok, copy the full URL, and try again."
        case .pageFetchFailed:
            return "TikTok didn't respond. Check your internet connection and try again."
        case .noHydration, .noItemStruct, .malformedJSON:
            return "Youty couldn't read this TikTok page. Try a different video."
        case .noVideoURL:
            return "TikTok didn't include a downloadable video for this post. It may be a slideshow or have been removed."
        case .wafChallengeUnsolvable:
            return "TikTok blocked the request. Wait a minute and try again, or open the link in TikTok first to refresh your session."
        }
    }
}

enum TikTokExtractor {

    // Desktop Safari 26 — matches what the TLS pretest used. Required by the
    // public webapp surface to return the full hydration payload (mobile UA
    // returns an app-redirect stub).
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    // MARK: - Entry point

    static func extract(url userInputURL: URL) async throws -> TikTokExtractionResult {
        let session = makeSession()

        // 1. Resolve the canonical URL (handles vm.tiktok.com / tiktok.com/t/).
        let canonical = try await resolveCanonical(url: userInputURL, session: session)
        guard let videoID = extractVideoID(from: canonical) else {
            throw TikTokExtractorError.malformedURL(canonical.absoluteString)
        }

        // 2. Fetch the page. Retry once with a freshly-solved WAF cookie if needed.
        let html = try await fetchPageWithChallengeHandling(url: canonical, session: session)

        // 3. Parse the hydration JSON.
        guard let hydration = extractHydration(from: html) else {
            throw TikTokExtractorError.noHydration
        }
        guard let itemStruct = navigateToItemStruct(in: hydration) else {
            throw TikTokExtractorError.noItemStruct
        }

        // 4. Pull metadata + URLs out of the itemStruct.
        let meta = try parseMetadata(itemStruct: itemStruct, videoID: videoID, url: canonical)
        guard let videoURL = pickVideoURL(itemStruct: itemStruct) else {
            throw TikTokExtractorError.noVideoURL
        }

        // 5. Fetch caption track if present.
        let captions = await fetchCaptions(itemStruct: itemStruct, session: session)

        return TikTokExtractionResult(
            metadata: meta,
            videoCDNURL: videoURL,
            videoDownloadHeaders: downloadHeaders(),
            captions: captions
        )
    }

    /// HTTP headers required by TikTok's webapp-prime CDN. Verified
    /// empirically (2026-05-12): without `Sec-Fetch-*`, `Origin`, and
    /// `Range`, the CDN returns 403 even for valid signed URLs. These match
    /// what a real Chrome/Safari tab sends when playing the video inline.
    static func downloadHeaders() -> [String: String] {
        return [
            "User-Agent": userAgent,
            "Referer": "https://www.tiktok.com/",
            "Origin": "https://www.tiktok.com",
            "Accept": "*/*",
            "Accept-Language": "en-US,en;q=0.9",
            "Sec-Fetch-Site": "cross-site",
            "Sec-Fetch-Mode": "cors",
            "Sec-Fetch-Dest": "video",
            "Range": "bytes=0-",
        ]
    }

    // MARK: - URL parsing + resolution

    /// Pulls a 19-digit (-ish) numeric video id out of TikTok URLs in any of
    /// the canonical web shapes.
    static func extractVideoID(from url: URL) -> String? {
        // /@user/video/12345  or /v/12345.html (mobile)
        if let m = url.path.range(of: #"/video/(\d{6,25})"#, options: .regularExpression) {
            let s = url.path[m]
            return s.components(separatedBy: "/").last
        }
        if let m = url.path.range(of: #"/v/(\d{6,25})"#, options: .regularExpression) {
            let s = url.path[m]
            return s.components(separatedBy: "/").last?.replacingOccurrences(of: ".html", with: "")
        }
        return nil
    }

    /// Follows redirects on short forms (vm.tiktok.com, tiktok.com/t/).
    private static func resolveCanonical(url: URL, session: URLSession) async throws -> URL {
        // Already canonical → fast path.
        if let host = url.host?.lowercased(),
           host == "www.tiktok.com" || host == "tiktok.com",
           extractVideoID(from: url) != nil {
            return url
        }
        // Issue a HEAD; if servers don't honor HEAD, fall back to GET that
        // follows redirects but reads no body.
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 8
        if let (_, resp) = try? await session.data(for: req),
           let final = (resp as? HTTPURLResponse)?.url ?? resp.url,
           extractVideoID(from: final) != nil {
            return final
        }
        // GET fallback.
        var get = URLRequest(url: url)
        get.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        get.timeoutInterval = 12
        let (_, resp) = try await session.data(for: get)
        if let final = (resp as? HTTPURLResponse)?.url ?? resp.url,
           extractVideoID(from: final) != nil {
            return final
        }
        throw TikTokExtractorError.couldNotResolveShortURL
    }

    // MARK: - Page fetch + WAF handling

    private static func fetchPageWithChallengeHandling(url: URL,
                                                       session: URLSession) async throws -> String {
        let html = try await fetchPage(url: url, session: session)
        if let challenge = WafChallenge.parse(html: html) {
            DebugLog.log("tiktok: WAF challenge detected; solving SHA-256 PoW")
            try challenge.solveAndStoreCookie(in: session)
            // Retry once.
            let html2 = try await fetchPage(url: url, session: session)
            if WafChallenge.parse(html: html2) != nil {
                throw TikTokExtractorError.wafChallengeUnsolvable
            }
            return html2
        }
        return html
    }

    private static func fetchPage(url: URL, session: URLSession) async throws -> String {
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        req.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                     forHTTPHeaderField: "Accept")
        req.timeoutInterval = 12

        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw TikTokExtractorError.pageFetchFailed(status) }
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - HTML → hydration JSON

    /// Extracts the JSON blob from
    /// `<script id="__UNIVERSAL_DATA_FOR_REHYDRATION__" type="application/json">…</script>`
    private static func extractHydration(from html: String) -> [String: Any]? {
        let needle = #"id="__UNIVERSAL_DATA_FOR_REHYDRATION__""#
        guard let idRange = html.range(of: needle) else { return nil }
        // Find the start of the JSON body after the `>` that closes the tag.
        guard let gt = html.range(of: ">", range: idRange.upperBound..<html.endIndex) else { return nil }
        let bodyStart = gt.upperBound
        guard let scriptEnd = html.range(of: "</script>", range: bodyStart..<html.endIndex) else { return nil }
        let jsonText = String(html[bodyStart..<scriptEnd.lowerBound])
        guard let data = jsonText.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    /// Navigates the hydration tree to the videoDetail itemStruct.
    /// Path: __DEFAULT_SCOPE__["webapp.video-detail"].itemInfo.itemStruct
    private static func navigateToItemStruct(in hydration: [String: Any]) -> [String: Any]? {
        guard let scope = hydration["__DEFAULT_SCOPE__"] as? [String: Any],
              let videoDetail = scope["webapp.video-detail"] as? [String: Any],
              let itemInfo = videoDetail["itemInfo"] as? [String: Any],
              let itemStruct = itemInfo["itemStruct"] as? [String: Any] else {
            return nil
        }
        return itemStruct
    }

    // MARK: - Metadata parsing

    private static func parseMetadata(itemStruct: [String: Any],
                                       videoID: String,
                                       url: URL) throws -> TikTokMetadata {
        let desc = (itemStruct["desc"] as? String) ?? ""
        let author = itemStruct["author"] as? [String: Any]
        let video = itemStruct["video"] as? [String: Any]
        let stats = itemStruct["stats"] as? [String: Any]
        let music = itemStruct["music"] as? [String: Any]

        let username = (author?["uniqueId"] as? String).map { "@\($0)" } ?? ""
        let displayName = (author?["nickname"] as? String) ?? ""

        let createTime = (itemStruct["createTime"] as? Int)
            ?? Int((itemStruct["createTime"] as? String) ?? "")
        let posted: Date? = createTime.map { Date(timeIntervalSince1970: TimeInterval($0)) }

        let duration: TimeInterval = (video?["duration"] as? Double)
            ?? Double((video?["duration"] as? Int) ?? 0)

        let width = (video?["width"] as? Int) ?? 0
        let height = (video?["height"] as? Int) ?? 0

        // TikTok occasionally returns counts as strings; coerce defensively.
        func intField(_ key: String, in dict: [String: Any]?) -> Int? {
            guard let dict else { return nil }
            if let v = dict[key] as? Int { return v }
            if let s = dict[key] as? String, let v = Int(s) { return v }
            return nil
        }

        let hashtags = parseHashtags(itemStruct: itemStruct, fallbackDesc: desc)

        return TikTokMetadata(
            videoID: videoID,
            url: url.absoluteString,
            description: desc,
            author: username,
            authorDisplayName: displayName,
            postedAt: posted,
            duration: duration,
            width: width,
            height: height,
            likes:    intField("diggCount", in: stats),
            comments: intField("commentCount", in: stats),
            shares:   intField("shareCount", in: stats),
            plays:    intField("playCount", in: stats),
            saves:    intField("collectCount", in: stats),
            musicTitle:  music?["title"] as? String,
            musicAuthor: music?["authorName"] as? String,
            musicAlbum:  music?["album"] as? String,
            hashtags: hashtags
        )
    }

    private static func parseHashtags(itemStruct: [String: Any], fallbackDesc: String) -> [String] {
        // Preferred: textExtra[].hashtagName (structured, no false positives).
        if let extras = itemStruct["textExtra"] as? [[String: Any]] {
            let tags = extras.compactMap { $0["hashtagName"] as? String }
                .filter { !$0.isEmpty }
                .map { $0.lowercased() }
            if !tags.isEmpty { return Array(Set(tags)).sorted() }
        }
        // Fallback: regex out of the desc.
        var found: Set<String> = []
        let scanner = Scanner(string: fallbackDesc)
        while !scanner.isAtEnd {
            _ = scanner.scanUpToString("#")
            if scanner.scanString("#") != nil,
               let tag = scanner.scanCharacters(from: .alphanumerics) {
                found.insert(tag.lowercased())
            }
        }
        return found.sorted()
    }

    // MARK: - Video URL picking

    /// Returns the best un-watermarked progressive MP4 URL. Prefers H.264 over
    /// HEVC for predictable VTDecompressionSession support; skips bytevc2
    /// (TikTok's experimental codec — undecodable).
    private static func pickVideoURL(itemStruct: [String: Any]) -> URL? {
        let video = itemStruct["video"] as? [String: Any]

        // bitrateInfo[] is the preferred path: explicit no-watermark, with
        // codec markers in UrlKey strings.
        if let bitrates = video?["bitrateInfo"] as? [[String: Any]] {
            // Sort: prefer h264, then higher bitrate (or higher implied quality
            // by ordering).
            let candidates: [(prefer: Int, dict: [String: Any])] = bitrates.compactMap { entry in
                guard let playAddr = entry["PlayAddr"] as? [String: Any] else { return nil }
                let urlKey = (entry["CodecType"] as? String)
                    ?? (playAddr["UrlKey"] as? String)
                    ?? ""
                let lower = urlKey.lowercased()
                let codecRank: Int
                if lower.contains("h264") { codecRank = 0 }
                else if lower.contains("bytevc1") || lower.contains("hevc") { codecRank = 1 }
                else if lower.contains("bytevc2") { return nil }  // unplayable
                else { codecRank = 2 }
                return (codecRank, entry)
            }.sorted { $0.prefer < $1.prefer }

            for (_, entry) in candidates {
                guard let playAddr = entry["PlayAddr"] as? [String: Any],
                      let urlList = playAddr["UrlList"] as? [String] else { continue }
                if let str = urlList.first(where: { !$0.contains("www.tiktok.com") }),
                   let url = URL(string: str) {
                    return url
                }
            }
        }

        // Older path: video.playAddr is a single string.
        if let direct = video?["playAddr"] as? String, let url = URL(string: direct) {
            return url
        }
        return nil
    }

    // MARK: - Captions

    private static func fetchCaptions(itemStruct: [String: Any],
                                       session: URLSession) async -> [TranscriptSegment]? {
        // Preferred: video.claInfo.captionInfos[] (structured webvtt/srt/json).
        // Schemas observed in the wild: both camelCase ("claInfo"/"captionInfos")
        // and snake_case ("cla_info"/"caption_infos"); accept both.
        let videoDict = itemStruct["video"] as? [String: Any]
        let claInfo = (videoDict?["claInfo"] as? [String: Any])
            ?? (videoDict?["cla_info"] as? [String: Any])
        if let claInfo,
           let infos = (claInfo["captionInfos"] as? [[String: Any]])
                       ?? (claInfo["caption_infos"] as? [[String: Any]]),
           let chosen = pickCaption(from: infos) {
            let urlStr = (chosen["url"] as? String) ?? (chosen["Url"] as? String) ?? ""
            let fmt = (chosen["Format"] as? String) ?? (chosen["format"] as? String) ?? ""
            if let url = URL(string: urlStr),
               let segs = await fetchAndParse(captionURL: url, format: fmt, session: session) {
                return segs
            }
        }

        // Legacy: video.subtitleInfos[] (capitalised keys).
        if let video = itemStruct["video"] as? [String: Any],
           let infos = video["subtitleInfos"] as? [[String: Any]],
           let chosen = pickCaption(from: infos),
           let url = (chosen["Url"] as? String).flatMap(URL.init(string:)),
           let fmt = (chosen["Format"] as? String) {
            if let segs = await fetchAndParse(captionURL: url, format: fmt, session: session) {
                return segs
            }
        }

        // App path: interaction_stickers[].auto_video_caption_info.auto_captions[].
        if let stickers = itemStruct["interaction_stickers"] as? [[String: Any]] {
            for sticker in stickers {
                guard let info = sticker["auto_video_caption_info"] as? [String: Any],
                      let autos = info["auto_captions"] as? [[String: Any]],
                      let chosen = pickCaption(from: autos),
                      let urlDict = chosen["url"] as? [String: Any],
                      let urlList = urlDict["url_list"] as? [String],
                      let urlStr = urlList.first,
                      let url = URL(string: urlStr) else { continue }
                if let segs = await fetchAndParse(captionURL: url, format: "json", session: session) {
                    return segs
                }
            }
        }
        return nil
    }

    /// Prefers English; falls back to the first available track. Strict English
    /// match avoids accidentally picking machine-translated tracks when an
    /// original exists.
    private static func pickCaption(from infos: [[String: Any]]) -> [String: Any]? {
        let lang = { (d: [String: Any]) -> String in
            (d["lang"] as? String)
                ?? (d["LanguageCodeName"] as? String)
                ?? (d["language"] as? String)
                ?? ""
        }
        if let en = infos.first(where: { lang($0).lowercased().hasPrefix("en") }) { return en }
        return infos.first
    }

    private static func fetchAndParse(captionURL: URL, format: String,
                                       session: URLSession) async -> [TranscriptSegment]? {
        var req = URLRequest(url: captionURL)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("https://www.tiktok.com/", forHTTPHeaderField: "Referer")
        req.timeoutInterval = 8
        guard let (data, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }

        let fmtLower = format.lowercased()
        let body = String(data: data, encoding: .utf8) ?? ""
        if fmtLower.contains("vtt") || body.hasPrefix("WEBVTT") {
            return parseWebVTT(body)
        }
        if fmtLower.contains("srt") {
            return parseSRT(body)
        }
        if fmtLower.contains("json") {
            return parseTikTokCaptionJSON(data)
        }
        // Heuristic on body if format string is missing.
        if body.contains("-->") { return parseWebVTT(body) }
        if body.contains("\n\n") && body.contains("-->") { return parseSRT(body) }
        if body.first == "{" { return parseTikTokCaptionJSON(data) }
        return nil
    }

    // MARK: - Caption format parsers

    /// Parses TikTok's auto-caption JSON: `{utterances: [{start_time, end_time, text}]}`
    /// `start_time` / `end_time` are in milliseconds.
    private static func parseTikTokCaptionJSON(_ data: Data) -> [TranscriptSegment]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let utterances = obj["utterances"] as? [[String: Any]] else { return nil }
        var out: [TranscriptSegment] = []
        out.reserveCapacity(utterances.count)
        for u in utterances {
            let text = ((u["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let startMs = (u["start_time"] as? Int)
                ?? Int((u["start_time"] as? Double) ?? 0)
            out.append(TranscriptSegment(
                text: text,
                timestamp: SpeechTranscriptionPipeline.formatTimestamp(seconds: Double(startMs) / 1000.0)
            ))
        }
        return out.isEmpty ? nil : out
    }

    /// Parses WebVTT cues: lines `HH:MM:SS.mmm --> HH:MM:SS.mmm` followed by text.
    private static func parseWebVTT(_ body: String) -> [TranscriptSegment]? {
        var out: [TranscriptSegment] = []
        let lines = body.components(separatedBy: .newlines)
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.contains("-->"),
               let arrow = line.range(of: "-->") {
                let startStr = line[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
                if let seconds = parseTimestampToSeconds(startStr) {
                    var text = ""
                    var j = i + 1
                    while j < lines.count, !lines[j].isEmpty {
                        if !text.isEmpty { text += " " }
                        text += lines[j].trimmingCharacters(in: .whitespaces)
                        j += 1
                    }
                    let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cleaned.isEmpty {
                        out.append(TranscriptSegment(
                            text: cleaned,
                            timestamp: SpeechTranscriptionPipeline.formatTimestamp(seconds: seconds)
                        ))
                    }
                    i = j
                    continue
                }
            }
            i += 1
        }
        return out.isEmpty ? nil : out
    }

    /// Parses SRT cues: numeric index, then `HH:MM:SS,mmm --> HH:MM:SS,mmm`,
    /// then text lines.
    private static func parseSRT(_ body: String) -> [TranscriptSegment]? {
        return parseWebVTT(body.replacingOccurrences(of: ",", with: "."))
    }

    private static func parseTimestampToSeconds(_ s: String) -> Double? {
        // Accept HH:MM:SS.mmm, MM:SS.mmm, SS.mmm; also commas in place of dots.
        let cleaned = s.replacingOccurrences(of: ",", with: ".")
        let parts = cleaned.split(separator: ":").map { String($0) }
        switch parts.count {
        case 3:
            guard let h = Double(parts[0]), let m = Double(parts[1]), let sec = Double(parts[2]) else { return nil }
            return h * 3600 + m * 60 + sec
        case 2:
            guard let m = Double(parts[0]), let sec = Double(parts[1]) else { return nil }
            return m * 60 + sec
        case 1:
            return Double(parts[0])
        default:
            return nil
        }
    }

    // MARK: - URLSession

    private static func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.default
        // Use the default cookie storage so any WAF cookies we set persist
        // across requests for the lifetime of this extraction.
        cfg.httpCookieStorage = HTTPCookieStorage.shared
        cfg.httpShouldSetCookies = true
        cfg.httpCookieAcceptPolicy = .always
        cfg.timeoutIntervalForRequest = 12
        cfg.timeoutIntervalForResource = 30
        cfg.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: cfg)
    }
}

// MARK: - WAF SHA-256 proof-of-work challenge

/// Solves TikTok's WAF challenge added in early 2026. When the page returns
/// a challenge stub instead of HTML, the body embeds three base64-encoded
/// JSON blobs under `<div id="cs">`, `<div id="wci">`, `<div id="rci">`.
/// The `cs` blob is `{v:{a: base64Bytes, c: base64Bytes}, ...}` plus the
/// cookie name to set. The solver brute-forces `i ∈ [0, 1_000_000]` such that
/// `SHA256(base64decode(a) || ascii(str(i))) == base64decode(c)`.
private struct WafChallenge {
    let cookieName: String
    let cookieValueTemplate: String   // contains `{i}` placeholder
    let prefix: Data                   // base64decode(a)
    let target: Data                   // base64decode(c)
    let domain: String                 // ".tiktok.com" typically

    static func parse(html: String) -> WafChallenge? {
        // Cheap pre-check: page must contain all three div ids to be a
        // challenge. Real pages don't have these as bare divs.
        guard html.contains(#"<div id="cs""#) ||
              html.contains(#"id="cs""#) && html.contains(#"id="wci""#)
        else { return nil }

        guard let csBody = innerText(of: "cs", in: html),
              let csData = Data(base64Encoded: csBody),
              let csObj = try? JSONSerialization.jsonObject(with: csData) as? [String: Any] else {
            return nil
        }
        guard let v = csObj["v"] as? [String: Any],
              let aB64 = v["a"] as? String,
              let cB64 = v["c"] as? String,
              let prefix = Data(base64Encoded: aB64),
              let target = Data(base64Encoded: cB64) else {
            return nil
        }
        let cookieName = (csObj["cookie"] as? String) ?? "_wafchallengeid"
        let valueTpl  = (csObj["value"] as? String)  ?? "{i}"
        let domain    = (csObj["domain"] as? String) ?? ".tiktok.com"
        return WafChallenge(
            cookieName: cookieName,
            cookieValueTemplate: valueTpl,
            prefix: prefix,
            target: target,
            domain: domain
        )
    }

    func solveAndStoreCookie(in session: URLSession) throws {
        // Brute force.
        for i in 0..<1_000_000 {
            var input = prefix
            input.append(contentsOf: String(i).utf8)
            let digest = SHA256.hash(data: input)
            if digestEquals(digest, target) {
                let value = cookieValueTemplate.replacingOccurrences(of: "{i}", with: String(i))
                let cookie = HTTPCookie(properties: [
                    .domain: domain,
                    .path: "/",
                    .name: cookieName,
                    .value: value,
                    .secure: "TRUE",
                ])
                if let c = cookie {
                    HTTPCookieStorage.shared.setCookie(c)
                    session.configuration.httpCookieStorage?.setCookie(c)
                }
                return
            }
        }
        throw TikTokExtractorError.wafChallengeUnsolvable
    }

    private func digestEquals(_ digest: SHA256.Digest, _ target: Data) -> Bool {
        guard target.count == 32 else { return false }
        return digest.elementsEqual(target)
    }

    /// Extracts the text content of `<div id="…">…</div>` (the challenge
    /// payload is plain base64 in the div body).
    private static func innerText(of divId: String, in html: String) -> String? {
        let needle = "id=\"\(divId)\""
        guard let idR = html.range(of: needle) else { return nil }
        guard let gt = html.range(of: ">", range: idR.upperBound..<html.endIndex) else { return nil }
        let bodyStart = gt.upperBound
        guard let endR = html.range(of: "</div>", range: bodyStart..<html.endIndex) else { return nil }
        return String(html[bodyStart..<endR.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
