import Foundation

/// YouTube's own captions, downloaded as a file through the same player API
/// the frame pipeline uses: no web page, no transcript panel to click. The
/// panel scrape stays the first choice (it also yields YouTube's summary), but
/// it times out on some long videos; this keeps those on YouTube's transcript
/// instead of falling back to on-device speech recognition.
enum YouTubeCaptions {

    /// Captions in the language spoken in the video, or nil when YouTube has none yet.
    static func transcript(videoID: String) async throws -> [TranscriptSegment]? {
        let list = try await StreamFetcher.fetchFormats(videoID: videoID)
        guard let track = bestTrack(list.captionTracks, spoken: originalLanguage(in: list.formats)),
              let url = json3URL(track) else { return nil }
        var request = URLRequest(url: url)
        request.setValue(list.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let segments = segments(json3: data)
        return segments.isEmpty ? nil : segments
    }

    /// The language of the video's original audio. Videos with AI-dubbed audio
    /// list one track per language and flag the original as the default.
    static func originalLanguage(in formats: [[String: Any]]) -> String? {
        for format in formats {
            guard let track = format["audioTrack"] as? [String: Any],
                  track["audioIsDefault"] as? Bool == true,
                  let id = track["id"] as? String else { continue }   // e.g. "en-US.4"
            return primaryLanguage(String(id.split(separator: ".").first ?? ""))
        }
        return nil
    }

    /// The track to save: the creator's own captions in the spoken language,
    /// else YouTube's automatic ones in that language. Dubbed videos carry
    /// automatic captions for every dub, so the language must be known first:
    /// from the original audio, or from the only automatic track there is.
    static func bestTrack(_ tracks: [[String: Any]], spoken: String?) -> [String: Any]? {
        func language(_ track: [String: Any]) -> String { primaryLanguage(track["languageCode"] as? String ?? "") }
        func automatic(_ track: [String: Any]) -> Bool { track["kind"] as? String == "asr" }
        let auto = tracks.filter(automatic)
        if let spoken = spoken ?? (auto.count == 1 ? language(auto[0]) : nil) {
            if let own = tracks.first(where: { !automatic($0) && language($0) == spoken }) { return own }
            if let generated = auto.first(where: { language($0) == spoken }) { return generated }
        }
        return tracks.first(where: { !automatic($0) })
            ?? auto.first(where: { language($0) == "en" })
            ?? tracks.first
    }

    static func json3URL(_ track: [String: Any]) -> URL? {
        guard let base = track["baseUrl"] as? String, var parts = URLComponents(string: base) else { return nil }
        parts.queryItems = (parts.queryItems ?? []).filter { $0.name != "fmt" && $0.name != "tlang" }
            + [URLQueryItem(name: "fmt", value: "json3")]
        return parts.url
    }

    /// Caption cues from YouTube's json3 format, one segment per cue.
    static func segments(json3 data: Data) -> [TranscriptSegment] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = root["events"] as? [[String: Any]] else { return [] }
        return events.compactMap { event in
            guard let start = (event["tStartMs"] as? NSNumber)?.intValue,
                  let pieces = event["segs"] as? [[String: Any]] else { return nil }
            let text = pieces.compactMap { $0["utf8"] as? String }.joined()
                .replacingOccurrences(of: "\n", with: " ")
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return text.isEmpty ? nil : TranscriptSegment(text: text, timestamp: timestamp(ms: start))
        }
    }

    /// "M:SS" under an hour, "H:MM:SS" over, like the transcript panel shows.
    static func timestamp(ms: Int) -> String {
        let seconds = max(0, ms) / 1000
        let (h, m, s) = (seconds / 3600, seconds / 60 % 60, seconds % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    private static func primaryLanguage(_ code: String) -> String {
        String(code.lowercased().split(separator: "-").first ?? "")
    }
}
