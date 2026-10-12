import Foundation

struct VideoMetadata {
    let videoID: String
    let title: String
    let channel: String
    let durationSeconds: Int
    let tags: [String]           // the creator's own keywords, cleaned
    let shortDescription: String
    let youtubeSummary: String   // empty when not available
    let dateSaved: String        // ISO8601
    var transcribedOnDevice = false  // no captions: transcript is on-device speech recognition
}

enum MetadataEnricher {

    static func enrich(from result: FetchResult) -> VideoMetadata {
        let vd = result.videoDetails
        let tags = Array(Tags.clean(vd.keywords).prefix(Tags.limit))

        return VideoMetadata(
            videoID:          vd.videoID,
            title:            vd.title,
            channel:          vd.author,
            durationSeconds:  vd.lengthSeconds,
            tags:             tags,
            shortDescription: vd.shortDescription,
            youtubeSummary:   vd.youtubeSummary,
            dateSaved:        ISO8601DateFormatter().string(from: Date()),
            transcribedOnDevice: result.transcriptSource == .onDeviceSpeech
        )
    }
}

/// Tag hygiene shared by saving and indexing. Creator keywords are the topic
/// signal; filler words, fragments, and duplicates only add noise to search.
enum Tags {
    static let limit = 20

    private static let filler: Set<String> = [
        "um", "uh", "uhm", "äh", "ähm", "hm", "hmm", "mhm", "eh", "ey", "oh", "ah", "wow",
        "nah", "yeah", "ja", "okay", "ok", "so", "well", "zack", "tja", "alter", "dude",
    ]

    /// Lowercased, trimmed, de-duplicated (first occurrence wins) tags with
    /// filler words, bare numbers, and single-letter fragments removed.
    static func clean(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags.compactMap { raw in
            var words = raw.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
            while let first = words.first, filler.contains(first) { words.removeFirst() }
            while let last = words.last, filler.contains(last) { words.removeLast() }
            let tag = words.joined(separator: " ")
            guard tag.filter(\.isLetter).count >= 2, seen.insert(tag).inserted else { return nil }
            return tag
        }
    }
}
