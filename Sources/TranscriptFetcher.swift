import Foundation

struct TranscriptSegment {
    let text: String
}

struct CaptionTrack: Decodable {
    let baseUrl: String
    let languageCode: String
}

struct TranscriptFetcher {

    // MARK: - Public

    static func fetch(urlString: String) async throws -> (title: String, markdown: String) {
        guard let videoID = extractVideoID(from: urlString) else {
            throw FetchError.invalidURL
        }
        let (title, tracks) = try await fetchPlayerResponse(videoID: videoID)
        guard let track = selectTrack(from: tracks) else {
            throw FetchError.noTranscript
        }
        guard let trackURL = URL(string: track.baseUrl) else {
            throw FetchError.noTranscript
        }
        let xml = try await fetchXML(from: trackURL)
        let segments = parseXML(xml)
        let markdown = formatMarkdown(title: title, segments: segments)
        return (title, markdown)
    }

    // MARK: - Video ID

    static func extractVideoID(from raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if !s.hasPrefix("http") { s = "https://" + s }
        guard let url = URL(string: s) else { return nil }
        let host = url.host ?? ""

        // youtu.be/{id}
        if host.contains("youtu.be") {
            let id = url.pathComponents.dropFirst().first
            return id?.isEmpty == false ? String(id!) : nil
        }

        // youtube.com/shorts/{id} or /embed/{id}
        let path = url.pathComponents
        if let idx = path.firstIndex(where: { $0 == "shorts" || $0 == "embed" }),
           idx + 1 < path.count {
            return path[idx + 1]
        }

        // youtube.com/watch?v={id}
        if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let v = comps.queryItems?.first(where: { $0.name == "v" })?.value,
           !v.isEmpty {
            return v
        }

        return nil
    }

    // MARK: - Player Response

    private static func fetchPlayerResponse(videoID: String) async throws -> (title: String, tracks: [CaptionTrack]) {
        guard let url = URL(string: "https://www.youtube.com/watch?v=\(videoID)") else {
            throw FetchError.invalidURL
        }
        var req = URLRequest(url: url)
        req.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw FetchError.networkError
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw FetchError.parseError
        }

        return try parsePlayerResponse(from: html)
    }

    private static func parsePlayerResponse(from html: String) throws -> (title: String, tracks: [CaptionTrack]) {
        // Extract ytInitialPlayerResponse JSON blob
        let pattern = #"ytInitialPlayerResponse\s*=\s*(\{.+?\});"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else {
            throw FetchError.parseError
        }

        let jsonString = String(html[range])
        guard let jsonData = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw FetchError.parseError
        }

        // Title
        let title: String
        if let details = json["videoDetails"] as? [String: Any],
           let t = details["title"] as? String {
            title = t
        } else {
            title = "YouTube Transcript"
        }

        // Caption tracks
        var tracks: [CaptionTrack] = []
        if let captions = json["captions"] as? [String: Any],
           let renderer = captions["playerCaptionsTracklistRenderer"] as? [String: Any],
           let rawTracks = renderer["captionTracks"] as? [[String: Any]] {
            for raw in rawTracks {
                if let baseUrl = raw["baseUrl"] as? String,
                   let lang = raw["languageCode"] as? String {
                    tracks.append(CaptionTrack(baseUrl: baseUrl, languageCode: lang))
                }
            }
        }

        return (title, tracks)
    }

    // MARK: - Track Selection

    private static func selectTrack(from tracks: [CaptionTrack]) -> CaptionTrack? {
        if let en = tracks.first(where: { $0.languageCode == "en" }) { return en }
        if let enAny = tracks.first(where: { $0.languageCode.hasPrefix("en") }) { return enAny }
        return tracks.first
    }

    // MARK: - XML Parsing

    private static func fetchXML(from url: URL) async throws -> String {
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let xml = String(data: data, encoding: .utf8) else { throw FetchError.parseError }
        return xml
    }

    private static func parseXML(_ xml: String) -> [TranscriptSegment] {
        let parser = TranscriptXMLParser()
        return parser.parse(xml)
    }

    // MARK: - Markdown Formatting

    static func formatMarkdown(title: String, segments: [TranscriptSegment]) -> String {
        let raw = segments.map(\.text).joined(separator: " ")
        let wrapped = wrapText(raw, lineWidth: 80)
        return "# \(title)\n\n\(wrapped)\n"
    }

    private static func wrapText(_ text: String, lineWidth: Int) -> String {
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var lines: [String] = []
        var current = ""

        for word in words {
            let candidate = current.isEmpty ? word : current + " " + word
            if candidate.count > lineWidth && !current.isEmpty {
                lines.append(current)
                current = word
            } else {
                current = candidate
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines.joined(separator: "\n")
    }
}

// MARK: - XML Parser

private class TranscriptXMLParser: NSObject, XMLParserDelegate {
    private var segments: [TranscriptSegment] = []
    private var currentText = ""
    private var inText = false

    func parse(_ xml: String) -> [TranscriptSegment] {
        guard let data = xml.data(using: .utf8) else { return [] }
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return segments
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        if name == "text" { inText = true; currentText = "" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { currentText += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                qualifiedName: String?) {
        if name == "text" {
            inText = false
            let clean = decodeHTMLEntities(currentText)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty { segments.append(TranscriptSegment(text: clean)) }
        }
    }

    private func decodeHTMLEntities(_ s: String) -> String {
        s
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }
}

// MARK: - Errors

enum FetchError: LocalizedError {
    case invalidURL
    case networkError
    case parseError
    case noTranscript

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "That doesn't look like a valid YouTube link."
        case .networkError: return "Couldn't reach YouTube. Check your connection."
        case .parseError: return "Couldn't read the video page. YouTube may have changed."
        case .noTranscript: return "This video has no available transcript."
        }
    }
}
