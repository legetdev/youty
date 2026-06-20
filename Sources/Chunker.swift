import Foundation

// Parses a video.md bundle file and yields the three Phase B chunk types
// (header / description / body). The chunk's `embeddingInput` carries the
// metadata prefix that anchors the vector in the right semantic
// neighbourhood (Anthropic contextual retrieval); `text` is the raw,
// prefix-free slice used for storage, FTS, and rerank.

struct Chunk {
    // `frameText` = text recognized on-screen via OCR (slides, code, captions
    // burned into the video) — searchable alongside the spoken transcript, but
    // tagged distinctly so callers can tell "shown" from "said".
    enum Kind: String { case header, description, body, frameText = "frame_text" }

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
        case .noFrontmatter:
            return "This saved video's note is malformed — its header is missing. Try saving again, or delete the bundle and re-save."
        case .readFailed:
            return "Couldn't read this saved video's note. The file may have moved or been deleted."
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
    let segments: [Segment]       // spoken transcript, "## Transcript"
    let frameTextSegments: [Segment]  // OCR'd on-screen text, "## On-screen text"

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
    // Conservative chars/token estimate. English averages ~4.0, but German (a
    // first-class language here — the embedder is multilingual and Bent's vault
    // is partly German) runs shorter, ~3.3. Using 3.5 slightly *over*-counts
    // tokens so target-sized chunks stay safely under the embedder's context in
    // real tokens rather than overflowing. Exact tokenization happens downstream
    // in EmbeddingGemma; this is only for chunk sizing.
    private static let charsPerToken: Double = 3.5
    // Hard ceiling on any chunk's embedding input. EmbeddingGemma's context is
    // 2048 tokens; staying well under it (room for the metadata prefix) means a
    // chunk can never be silently truncated at embed time, losing its tail from
    // search. Splitting enforces this for descriptions and oversized segments.
    private static let maxChunkTokens = 1800

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
        let segments = extractSegments(from: body, heading: "## Transcript")
        let frameTextSegments = extractSegments(from: body, heading: "## On-screen text")

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
            segments:        segments,
            frameTextSegments: frameTextSegments
        )
    }

    // MARK: - Chunking

    static func chunk(parsed p: ParsedVideoMd) -> [Chunk] {
        var chunks: [Chunk] = []
        chunks.append(makeHeader(parsed: p))
        chunks.append(contentsOf: makeDescriptionChunks(parsed: p))
        chunks.append(contentsOf: makeBodyChunks(parsed: p))
        chunks.append(contentsOf: makeFrameTextChunks(parsed: p))
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

    private static func makeDescriptionChunks(parsed p: ParsedVideoMd) -> [Chunk] {
        let body = p.descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return [] }
        let combinedRough = "\(p.title)\n\(p.channel)\n\n\(body)"
        if approxTokens(combinedRough) < descriptionMinTokens { return [] }
        // Long descriptions (some YouTube descriptions run thousands of tokens)
        // are split so no single chunk overflows the embedder and loses its tail.
        let pieces = splitText(body, target: bodyTargetTokens, overlap: bodyOverlapTokens)
        return pieces.enumerated().map { i, piece in
            let embeddingInput = "Title: \(p.title)\nChannel: \(p.channel)\n\n\(piece)"
            return Chunk(type: .description,
                         index: i,
                         text: piece,
                         embeddingInput: embeddingInput,
                         startMs: nil,
                         endMs: nil)
        }
    }

    private static func makeBodyChunks(parsed p: ParsedVideoMd) -> [Chunk] {
        timestampedChunks(parsed: p, segments: p.segments, kind: .body)
    }

    /// OCR'd on-screen text → searchable chunks, bucketed exactly like the
    /// transcript but tagged `.frameText` and prefixed so both the vector and
    /// the reading AI know this is what was *shown*, not *said*.
    private static func makeFrameTextChunks(parsed p: ParsedVideoMd) -> [Chunk] {
        timestampedChunks(parsed: p, segments: p.frameTextSegments, kind: .frameText)
    }

    /// Shared bucketer for timestamped segment streams (transcript + on-screen
    /// text). Accumulates whole segments to ~400 tokens with a 60-token overlap
    /// carried between chunks; oversized single segments are pre-split so no
    /// chunk overflows the embedder.
    private static func timestampedChunks(parsed p: ParsedVideoMd,
                                          segments rawSegments: [ParsedVideoMd.Segment],
                                          kind: Chunk.Kind) -> [Chunk] {
        guard !rawSegments.isEmpty else { return [] }
        let segments = explodeOversizedSegments(rawSegments)

        struct Bucket { var segments: [ParsedVideoMd.Segment] = []; var tokens: Int = 0 }
        var out: [Chunk] = []
        var bucket = Bucket()
        var idx = 0

        func flush() {
            guard !bucket.segments.isEmpty else { return }
            let start = bucket.segments.first!.startMs
            let end = bucket.segments.last!.endMs ?? bucket.segments.last!.startMs
            let raw = bucket.segments.map { "[\(formatTimestamp($0.startMs))] \($0.text)" }.joined(separator: "\n")
            let embedInput = timestampedEmbeddingInput(parsed: p, kind: kind, startMs: start, endMs: end, text: raw)
            out.append(Chunk(type: kind, index: idx, text: raw, embeddingInput: embedInput, startMs: start, endMs: end))
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

        for seg in segments {
            bucket.segments.append(seg)
            bucket.tokens += approxTokens(seg.text)
            if bucket.tokens >= bodyTargetTokens { flush() }
        }
        // Final flush — skip if the trailing bucket is only the overlap tail
        // re-prepended after the previous flush (no genuinely new segments).
        if !bucket.segments.isEmpty {
            let overlapOnly: Bool = {
                guard let lastChunk = out.last else { return false }
                let lastEndMs = lastChunk.endMs ?? -1
                let firstStart = bucket.segments.first?.startMs ?? -2
                return bucket.segments.allSatisfy { $0.startMs <= lastEndMs } && firstStart <= lastEndMs
            }()
            if !overlapOnly { flush() }
        }
        return out
    }

    private static func timestampedEmbeddingInput(parsed p: ParsedVideoMd,
                                                  kind: Chunk.Kind,
                                                  startMs: Int,
                                                  endMs: Int,
                                                  text: String) -> String {
        let tags = p.tags.joined(separator: ", ")
        let ts = "[\(formatTimestamp(startMs)) – \(formatTimestamp(endMs))]"
        let sourceLine = kind == .frameText ? "\nSource: on-screen text (OCR)" : ""
        return """
        Title: \(p.title)
        Channel: \(p.channel)
        Platform: \(p.platform)
        Tags: \(tags)
        Timestamp: \(ts)\(sourceLine)

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

    /// Walks the `heading` section's lines of the shape "[mm:ss] text" (or
    /// "[h:mm:ss] text"). Used for both "## Transcript" (spoken) and
    /// "## On-screen text" (OCR'd). Each line becomes one Segment; endMs is
    /// filled in from the next segment's start (last segment's endMs is left nil
    /// and the body chunker substitutes its startMs).
    private static func extractSegments(from body: String, heading: String) -> [ParsedVideoMd.Segment] {
        let lines = body.components(separatedBy: "\n")
        var inSection = false
        var raws: [(ms: Int, text: String)] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == heading {
                inSection = true
                continue
            }
            if trimmed.hasPrefix("## ") {
                if inSection { break }
                continue
            }
            guard inSection else { continue }
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

    // MARK: - Splitting (keep every chunk under the embedder's context)

    /// Split any segment whose text already exceeds the chunk target into
    /// sentence-grouped sub-segments, interpolating timestamps across the
    /// segment's span so each piece still maps to the right frame. Segments at
    /// or under target pass through untouched.
    private static func explodeOversizedSegments(_ segs: [ParsedVideoMd.Segment]) -> [ParsedVideoMd.Segment] {
        var out: [ParsedVideoMd.Segment] = []
        for seg in segs {
            if approxTokens(seg.text) <= bodyTargetTokens { out.append(seg); continue }
            let pieces = splitText(seg.text, target: bodyTargetTokens, overlap: 0)
            let span = (seg.endMs ?? seg.startMs) - seg.startMs
            let n = max(pieces.count, 1)
            for (i, piece) in pieces.enumerated() {
                let s = seg.startMs + (span * i / n)
                let e = seg.endMs == nil ? nil : seg.startMs + (span * (i + 1) / n)
                out.append(.init(startMs: s, endMs: e, text: piece))
            }
        }
        return out
    }

    /// Split prose into ~`target`-token pieces at sentence boundaries, carrying
    /// `overlap` tokens between pieces. Sentence segmentation is locale-aware
    /// (`.bySentences`), so it handles German and other languages correctly. A
    /// single sentence longer than `target` (e.g. unpunctuated ASR) falls back
    /// to word-splitting, guaranteeing no piece exceeds `maxChunkTokens`.
    static func splitText(_ text: String, target: Int, overlap: Int) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }
        if approxTokens(trimmed) <= target { return [trimmed] }

        let sentences = splitIntoSentences(trimmed)
        var pieces: [String] = []
        var cur: [String] = []
        var curTok = 0

        func flush(carryOverlap: Bool) {
            guard !cur.isEmpty else { return }
            pieces.append(cur.joined(separator: " ").trimmingCharacters(in: .whitespaces))
            guard carryOverlap, overlap > 0 else { cur = []; curTok = 0; return }
            var tail: [String] = []; var t = 0
            for u in cur.reversed() {
                let k = approxTokens(u)
                if t + k > overlap { break }
                tail.insert(u, at: 0); t += k
            }
            cur = tail; curTok = t
        }

        for unit in sentences {
            if approxTokens(unit) > target {
                // A single oversized sentence: flush, then hard word-split it.
                flush(carryOverlap: false)
                pieces.append(contentsOf: wordSplit(unit, target: target))
                continue
            }
            cur.append(unit); curTok += approxTokens(unit)
            if curTok >= target { flush(carryOverlap: true) }
        }
        flush(carryOverlap: false)
        return pieces.filter { !$0.isEmpty }
    }

    /// Locale-aware sentence segmentation. Falls back to newline/whitespace
    /// splitting if the platform returns nothing (defensive).
    private static func splitIntoSentences(_ text: String) -> [String] {
        var out: [String] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex,
                                 options: [.bySentences, .localized]) { sub, _, _, _ in
            if let s = sub?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                out.append(s)
            }
        }
        if out.isEmpty {
            out = text.split(whereSeparator: { $0 == "\n" })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        return out.isEmpty ? [text] : out
    }

    /// Last-resort splitter for a single unit with no usable sentence breaks:
    /// group words up to `target` tokens (hard-capped at `maxChunkTokens`).
    private static func wordSplit(_ text: String, target: Int) -> [String] {
        let cap = min(max(target, 1), maxChunkTokens)
        let words = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
        var out: [String] = []
        var cur: [Substring] = []
        var tok = 0
        for w in words {
            cur.append(w); tok += approxTokens(String(w))
            if tok >= cap { out.append(cur.joined(separator: " ")); cur = []; tok = 0 }
        }
        if !cur.isEmpty { out.append(cur.joined(separator: " ")) }
        return out.isEmpty ? [text] : out
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
