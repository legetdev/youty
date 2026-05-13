import Foundation

// Parses a video.md bundle file and yields the three Phase B chunk types
// (header / description / body). The chunk's `embeddingInput` carries the
// metadata prefix that anchors the vector in the right semantic
// neighbourhood (Anthropic contextual retrieval); `text` is the raw,
// prefix-free slice used for storage, FTS, and rerank.

struct Chunk {
    enum Kind: String { case header, description, body }

    let type: Kind
    let index: Int          // 0 for header / description; 0..N for body
    let text: String        // raw text (no metadata prefix)
    let embeddingInput: String
    let startMs: Int?       // nil for header / description
    let endMs: Int?
}

enum ChunkerError: LocalizedError {
    case noFrontmatter
    case readFailed(Error)
    var errorDescription: String? {
        switch self {
        case .noFrontmatter:        return "video.md is missing its YAML frontmatter."
        case .readFailed(let e):    return "Could not read video.md: \(e.localizedDescription)"
        }
    }
}

/// Parsed view of a video.md file. Mirrors the frontmatter fields the
/// indexer needs to write into the `videos` table plus the raw transcript
/// segments + description body the chunker operates on.
struct ParsedVideoMd {
    struct Segment { let startMs: Int; let endMs: Int?; let text: String }

    let frontmatter: [String: String]
    let platform: String        // youtube | instagram | tiktok
    let videoID: String         // platform-agnostic id (raw, no prefix)
    let title: String
    let channel: String
    let url: String
    let durationMs: Int?
    let dateSavedUnixMs: Int
    let tags: [String]
    let descriptionText: String   // caption / description / summary, joined
    let segments: [Segment]

    /// Platform-qualified id used as `videos.video_id` in the index.
    var qualifiedID: String {
        switch platform {
        case "youtube":   return "yt:\(videoID)"
        case "instagram": return "ig:\(videoID)"
        case "tiktok":    return "tt:\(videoID)"
        default:          return "\(platform):\(videoID)"
        }
    }

    /// Pretty duration label like "12:34" — used in the metadata prefix the
    /// embedder sees. Falls back to whatever the frontmatter carried.
    var durationLabel: String {
        if let raw = frontmatter["duration"], !raw.isEmpty { return raw }
        guard let ms = durationMs else { return "" }
        let s = ms / 1000
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                     : String(format: "%d:%02d", m, sec)
    }
}

enum Chunker {

    private static let bodyTargetTokens = 400
    private static let bodyOverlapTokens = 60
    private static let descriptionMinTokens = 50
    private static let charsPerToken: Double = 4.0

    /// Loads `video.md` and returns a parsed view + the chunks for it.
    static func parseAndChunk(videoMdURL: URL) throws -> (parsed: ParsedVideoMd, chunks: [Chunk]) {
        let text: String
        do { text = try String(contentsOf: videoMdURL, encoding: .utf8) }
        catch { throw ChunkerError.readFailed(error) }
        let parsed = try parse(text: text)
        let chunks = chunk(parsed: parsed)
        return (parsed, chunks)
    }

    // MARK: - Parsing

    static func parse(text: String) throws -> ParsedVideoMd {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.hasPrefix("---") == true else { throw ChunkerError.noFrontmatter }
        guard let closeIdx = lines.dropFirst().firstIndex(of: "---") else {
            throw ChunkerError.noFrontmatter
        }

        var kv: [String: String] = [:]
        for i in 1..<closeIdx {
            let line = lines[i]
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            kv[parts[0]] = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }

        let platform = kv["platform"] ?? "youtube"
        let videoID = kv["video_id"] ?? kv["post_id"] ?? ""
        let title = kv["title"] ?? ""
        let channel = kv["channel"] ?? kv["author_display_name"] ?? kv["author"] ?? ""
        let urlStr = kv["url"] ?? defaultURL(for: platform, id: videoID)
        let durationMs = parseDurationLabelToMs(kv["duration"] ?? "")

        let tagsRaw = kv["tags"] ?? kv["hashtags"] ?? "[]"
        let tags = tagsRaw
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            .filter { !$0.isEmpty }

        let dateSavedMs = parseDateSavedToUnixMs(kv["date_saved"] ?? "")

        // Body of the markdown lives after the second '---'.
        let bodyStart = closeIdx + 1
        let body = bodyStart < lines.count
            ? lines[bodyStart...].joined(separator: "\n")
            : ""

        let descriptionText = extractDescription(from: body)
        let segments = extractSegments(from: body)

        return ParsedVideoMd(
            frontmatter:     kv,
            platform:        platform,
            videoID:         videoID,
            title:           title,
            channel:         channel,
            url:             urlStr,
            durationMs:      durationMs,
            dateSavedUnixMs: dateSavedMs,
            tags:            tags,
            descriptionText: descriptionText,
            segments:        segments
        )
    }

    // MARK: - Chunking

    static func chunk(parsed p: ParsedVideoMd) -> [Chunk] {
        var chunks: [Chunk] = []
        chunks.append(makeHeader(parsed: p))

        if let desc = makeDescription(parsed: p) {
            chunks.append(desc)
        }

        let body = makeBodyChunks(parsed: p)
        chunks.append(contentsOf: body)
        return chunks
    }

    private static func makeHeader(parsed p: ParsedVideoMd) -> Chunk {
        let tags = p.tags.joined(separator: ", ")
        var lines: [String] = []
        lines.append("Title: \(p.title)")
        lines.append("Channel: \(p.channel)")
        lines.append("Platform: \(p.platform)")
        lines.append("Tags: \(tags)")
        lines.append("Duration: \(p.durationLabel)")
        let text = lines.joined(separator: "\n")
        // Header's embedding input *is* the metadata literal — no prefix.
        return Chunk(type: .header,
                     index: 0,
                     text: text,
                     embeddingInput: text,
                     startMs: nil,
                     endMs: nil)
    }

    private static func makeDescription(parsed p: ParsedVideoMd) -> Chunk? {
        let body = p.descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        let combinedRough = "\(p.title)\n\(p.channel)\n\n\(body)"
        if approxTokens(combinedRough) < descriptionMinTokens { return nil }
        let embeddingInput = "Title: \(p.title)\nChannel: \(p.channel)\n\n\(body)"
        return Chunk(type: .description,
                     index: 0,
                     text: body,
                     embeddingInput: embeddingInput,
                     startMs: nil,
                     endMs: nil)
    }

    private static func makeBodyChunks(parsed p: ParsedVideoMd) -> [Chunk] {
        guard !p.segments.isEmpty else { return [] }

        // Walk segments, accumulating to ~400 tokens; flush when ≥400.
        // Maintain 60-token overlap by re-prepending tail segments of the
        // previous chunk on each flush.
        struct Bucket { var segments: [ParsedVideoMd.Segment] = []; var tokens: Int = 0 }

        var out: [Chunk] = []
        var bucket = Bucket()
        var idx = 0

        func flush() {
            guard !bucket.segments.isEmpty else { return }
            let start = bucket.segments.first!.startMs
            let end = bucket.segments.last!.endMs ?? bucket.segments.last!.startMs
            let raw = bucket.segments.map { "[\(formatTimestamp($0.startMs))] \($0.text)" }.joined(separator: "\n")
            let embedInput = bodyEmbeddingInput(parsed: p, startMs: start, endMs: end, text: raw)
            out.append(Chunk(type: .body,
                             index: idx,
                             text: raw,
                             embeddingInput: embedInput,
                             startMs: start,
                             endMs: end))
            idx += 1
            // Carry tail segments for overlap.
            var tail: [ParsedVideoMd.Segment] = []
            var tailTokens = 0
            for seg in bucket.segments.reversed() {
                let t = approxTokens(seg.text)
                if tailTokens + t > bodyOverlapTokens { break }
                tail.insert(seg, at: 0)
                tailTokens += t
            }
            bucket = Bucket()
            bucket.segments = tail
            bucket.tokens = tailTokens
        }

        for seg in p.segments {
            let tk = approxTokens(seg.text)
            // Always add the segment whole (never split a segment), then
            // flush if we crossed the target.
            bucket.segments.append(seg)
            bucket.tokens += tk
            if bucket.tokens >= bodyTargetTokens {
                flush()
            }
        }
        // Final flush — but skip if the trailing bucket is only the overlap
        // tail re-prepended after the previous flush (no new segments).
        if !bucket.segments.isEmpty {
            if out.isEmpty || bucket.tokens > 0 {
                // Detect "only overlap" by checking that at least one segment
                // is *not* the tail of the previous chunk. Simplest heuristic:
                // if the bucket's first segment's start equals the previous
                // chunk's last segment's start, and the count matches the
                // overlap, skip.
                let overlapOnly: Bool = {
                    guard let lastChunk = out.last else { return false }
                    let lastEndMs = lastChunk.endMs ?? -1
                    let firstStart = bucket.segments.first?.startMs ?? -2
                    // If every segment in bucket has start <= lastEndMs, it's pure overlap.
                    return bucket.segments.allSatisfy { $0.startMs <= lastEndMs } &&
                           firstStart <= lastEndMs
                }()
                if !overlapOnly { flush() }
            }
        }

        return out
    }

    private static func bodyEmbeddingInput(parsed p: ParsedVideoMd,
                                            startMs: Int,
                                            endMs: Int,
                                            text: String) -> String {
        let tags = p.tags.joined(separator: ", ")
        let ts = "[\(formatTimestamp(startMs)) – \(formatTimestamp(endMs))]"
        return """
        Title: \(p.title)
        Channel: \(p.channel)
        Platform: \(p.platform)
        Tags: \(tags)
        Timestamp: \(ts)

        \(text)
        """
    }

    // MARK: - Description section extraction

    /// Pulls out the caption / description / summary section(s). Handles all
    /// three video.md flavours:
    ///   YouTube  → "## Description" + "## Summary"
    ///   IG       → "## Caption"
    ///   TikTok   → "## Description"
    private static func extractDescription(from body: String) -> String {
        let candidates = ["## Caption", "## Description", "## Summary"]
        let lines = body.components(separatedBy: "\n")
        var collected: [String] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if candidates.contains(line.trimmingCharacters(in: .whitespaces)) {
                // Collect until the next "## …" heading (or EOF).
                i += 1
                var section: [String] = []
                while i < lines.count {
                    let l = lines[i]
                    if l.hasPrefix("## ") { break }
                    section.append(l)
                    i += 1
                }
                let joined = section.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !joined.isEmpty { collected.append(joined) }
                continue
            }
            i += 1
        }
        return collected.joined(separator: "\n\n")
    }

    // MARK: - Transcript segment extraction

    /// Walks "## Transcript" lines of the shape "[mm:ss] text" (or "[h:mm:ss] text").
    /// Each line becomes one Segment; endMs is filled in from the next
    /// segment's start (last segment's endMs is left nil and the body chunker
    /// substitutes its startMs).
    private static func extractSegments(from body: String) -> [ParsedVideoMd.Segment] {
        let lines = body.components(separatedBy: "\n")
        var inTranscript = false
        var raws: [(ms: Int, text: String)] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "## Transcript" {
                inTranscript = true
                continue
            }
            if trimmed.hasPrefix("## ") {
                if inTranscript { break }
                continue
            }
            guard inTranscript else { continue }
            // Skip placeholder / empty lines.
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("_") { continue }
            // Expect "[mm:ss] text"
            guard let bracketEnd = trimmed.firstIndex(of: "]"),
                  trimmed.hasPrefix("[") else { continue }
            let ts = String(trimmed[trimmed.index(after: trimmed.startIndex)..<bracketEnd])
            let rest = trimmed[trimmed.index(after: bracketEnd)...].trimmingCharacters(in: .whitespaces)
            guard let ms = parseTimestampLabelToMs(ts) else { continue }
            raws.append((ms, String(rest)))
        }
        // Pair consecutive starts into (startMs, endMs).
        var segs: [ParsedVideoMd.Segment] = []
        for (i, item) in raws.enumerated() {
            let end: Int? = (i + 1 < raws.count) ? raws[i + 1].ms : nil
            segs.append(.init(startMs: item.ms, endMs: end, text: item.text))
        }
        return segs
    }

    // MARK: - Token / timestamp utilities

    private static func approxTokens(_ s: String) -> Int {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return 0 }
        return max(1, Int(ceil(Double(trimmed.count) / charsPerToken)))
    }

    private static func formatTimestamp(_ ms: Int) -> String {
        let s = ms / 1000
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                     : String(format: "%d:%02d", m, sec)
    }

    /// "1:23" or "1:02:03" → ms; nil on parse failure.
    static func parseTimestampLabelToMs(_ s: String) -> Int? {
        let parts = s.split(separator: ":").map(String.init)
        guard !parts.isEmpty else { return nil }
        var h = 0, m = 0, sec = 0
        switch parts.count {
        case 1: guard let v = Int(parts[0]) else { return nil }; sec = v
        case 2: guard let a = Int(parts[0]), let b = Int(parts[1]) else { return nil }; m = a; sec = b
        case 3: guard let a = Int(parts[0]), let b = Int(parts[1]), let c = Int(parts[2]) else { return nil }; h = a; m = b; sec = c
        default: return nil
        }
        return ((h * 3600) + (m * 60) + sec) * 1000
    }

    private static func parseDurationLabelToMs(_ s: String) -> Int? {
        guard !s.isEmpty else { return nil }
        return parseTimestampLabelToMs(s)
    }

    /// Accepts an ISO8601 string ("2025-04-21T…Z") and returns unix epoch ms.
    /// Falls back to "now" — the indexer always needs a value for the column.
    private static func parseDateSavedToUnixMs(_ s: String) -> Int {
        if s.isEmpty { return Int(Date().timeIntervalSince1970 * 1000) }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return Int(d.timeIntervalSince1970 * 1000) }
        let f2 = ISO8601DateFormatter()
        if let d = f2.date(from: s) { return Int(d.timeIntervalSince1970 * 1000) }
        return Int(Date().timeIntervalSince1970 * 1000)
    }

    private static func defaultURL(for platform: String, id: String) -> String {
        switch platform {
        case "tiktok":    return "https://www.tiktok.com/"
        case "instagram": return "https://www.instagram.com/p/\(id)/"
        default:          return "https://www.youtube.com/watch?v=\(id)"
        }
    }
}
