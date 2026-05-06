import NaturalLanguage
import Foundation

struct VideoMetadata {
    let videoID: String
    let title: String
    let channel: String
    let durationSeconds: Int
    let tags: [String]           // creator keywords + NL entities, merged and lowercased
    let shortDescription: String
    let youtubeSummary: String   // empty when not available
    let dateSaved: String        // ISO8601
}

enum MetadataEnricher {

    static func enrich(from result: FetchResult) -> VideoMetadata {
        let vd = result.videoDetails
        let fullText = result.segments.map(\.text).joined(separator: " ")
        let entities = extractEntities(from: fullText)
        let tags = Array(Set(vd.keywords.map { $0.lowercased() } + entities)).sorted()

        return VideoMetadata(
            videoID:          vd.videoID,
            title:            vd.title,
            channel:          vd.author,
            durationSeconds:  vd.lengthSeconds,
            tags:             tags,
            shortDescription: vd.shortDescription,
            youtubeSummary:   vd.youtubeSummary,
            dateSaved:        ISO8601DateFormatter().string(from: Date())
        )
    }

    // NLTagger returns proper nouns: people, organisations, places.
    // Creator-set keywords are the primary topic signal; entities fill the gaps.
    private static func extractEntities(from text: String) -> [String] {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var found: Set<String> = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex,
                             unit: .word,
                             scheme: .nameType,
                             options: [.omitPunctuation, .omitWhitespace, .joinNames]) { tag, range in
            if let tag, [.personalName, .organizationName, .placeName].contains(tag) {
                found.insert(String(text[range]).lowercased())
            }
            return true
        }
        return Array(found)
    }
}
