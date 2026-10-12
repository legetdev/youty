import Foundation

// Parses a video.md bundle file and yields its chunks (header, description,
// spoken transcript, on-screen text). A chunk's `embeddingInput` is the text in
// EmbeddingGemma 2's document format, anchored by the video title; `text` is
// the plain content used for storage, keyword search, and agent responses.

struct Chunk {
    // `frameText` = text recognized on-screen via OCR (slides, code, captions
    // burned into the video) — searchable alongside the spoken transcript, but
    // tagged distinctly so callers can tell "shown" from "said".
    enum Kind: String { case header, description, body, frameText = "frame_text" }

    let type: Kind
    let index: Int          // position within its kind, from 0
    let text: String        // plain content (no prompt or title)
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

    /// Counts model tokens in `text`, excluding `<bos>`/`<eos>`.
    typealias TokenCounter = (String) -> Int

    /// Content tokens per chunk (≈1–2 minutes of speech). With the document
    /// prompt, the video title, and the carried overlap, every embedding input
    /// stays well inside EmbeddingGemma 2's 512-token window.
    static let targetTokens = 360
    static let overlapTokens = 48
    static let maxInputTokens = 500
    private static let descriptionMinTokens = 50
    /// Rough characters-per-token for callers without the model tokenizer
    /// (tests, parse-only paths). German runs shorter than English, so 3.5
    /// slightly over-counts and keeps estimates on the safe side.
    private static let charsPerToken: Double = 3.5

    /// Loads `video.md` and returns a parsed view + the chunks for it.
    static func parseAndChunk(videoMdURL: URL,
                              tokens: TokenCounter = approxTokens) throws -> (parsed: ParsedVideoMd, chunks: [Chunk]) {
        let text: String
        do { text = try String(contentsOf: videoMdURL, encoding: .utf8) }
        catch { throw ChunkerError.readFailed(error) }
        let parsed = try parse(text: text)
        let chunks = chunk(parsed: parsed, tokens: tokens)
        return (parsed, chunks)
    }

    // MARK: - Parsing

    /// Value of a frontmatter scalar. Double-quoted values use the JSON-compatible
    /// escapes `VaultManager` writes (`\"`, `\\`), so decode them as JSON strings.
    nonisolated static func frontmatterScalar(_ raw: String) -> String {
        if raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\""),
           let value = try? JSONDecoder().decode(String.self, from: Data(raw.utf8)) {
            return value
        }
        return raw.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    /// Items of an inline frontmatter list such as `["a", "b, c"]`.
    nonisolated static func frontmatterList(_ raw: String) -> [String] {
        if let items = try? JSONDecoder().decode([String].self, from: Data(raw.utf8)) {
            return items.filter { !$0.isEmpty }
        }
        return raw
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .components(separatedBy: ",")
            .map { frontmatterScalar($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
    }

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
            kv[parts[0]] = frontmatterScalar(parts[1])
        }

        let platform = kv["platform"] ?? "youtube"
        let videoID = kv["video_id"] ?? kv["post_id"] ?? ""
        let title = kv["title"] ?? ""
        let channel = kv["channel"] ?? kv["author_display_name"] ?? kv["author"] ?? ""
        let urlStr = kv["url"] ?? defaultURL(for: platform, id: videoID)
        let durationMs = parseDurationLabelToMs(kv["duration"] ?? "")

        let tagsRaw = kv["tags"] ?? kv["hashtags"] ?? "[]"
        let tags = frontmatterList(tagsRaw)

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

    /// Header, description, spoken transcript, and on-screen text chunks. Each
    /// chunk's embedding input uses EmbeddingGemma 2's native document format
    /// with the video title in the title slot; the stored `text` is the plain
    /// content agents read back.
    static func chunk(parsed p: ParsedVideoMd, tokens: TokenCounter = approxTokens) -> [Chunk] {
        var chunks = [makeHeader(parsed: p)]
        chunks += makeDescriptionChunks(parsed: p, tokens: tokens)
        chunks += timestampedChunks(parsed: p, segments: p.segments, kind: .body, tokens: tokens)
        chunks += timestampedChunks(parsed: p, segments: p.frameTextSegments, kind: .frameText, tokens: tokens)
        return chunks
    }

    private static func makeHeader(parsed p: ParsedVideoMd) -> Chunk {
        var lines = [p.title]
        if !p.channel.isEmpty { lines.append("By \(p.channel) on \(p.platform.capitalized)") }
        let topics = Tags.clean(p.tags).prefix(15)
        if !topics.isEmpty { lines.append("Topics: \(topics.joined(separator: ", "))") }
        if !p.durationLabel.isEmpty { lines.append("Length: \(p.durationLabel)") }
        let text = lines.joined(separator: "\n")
        return Chunk(type: .header, index: 0, text: text,
                     embeddingInput: EmbeddingGemma2.documentInput(title: p.title, text: text),
                     startMs: nil, endMs: nil)
    }

    /// Content budget for one chunk of this video: the target, minus whatever
    /// the prompt, title, and overlap take from the model window.
    private static func contentBudget(title: String, tokens: TokenCounter) -> Int {
        let reserve = tokens(EmbeddingGemma2.documentInput(title: title, text: "")) + 2
        return max(64, min(targetTokens, maxInputTokens - reserve - overlapTokens))
    }

    private static func makeDescriptionChunks(parsed p: ParsedVideoMd, tokens: TokenCounter) -> [Chunk] {
        let body = p.descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, tokens(body) >= descriptionMinTokens else { return [] }
        let budget = contentBudget(title: p.title, tokens: tokens)
        return splitText(body, target: budget, overlap: overlapTokens, tokens: tokens)
            .enumerated().map { i, piece in
                Chunk(type: .description, index: i, text: piece,
                      embeddingInput: EmbeddingGemma2.documentInput(title: p.title, text: piece),
                      startMs: nil, endMs: nil)
            }
    }

    /// Accumulates whole timestamped segments (transcript lines or on-screen
    /// text entries) up to the content budget, carrying a short overlap between
    /// chunks. Spoken text is stored as prose; on-screen text keeps one
    /// timestamped line per changed screen so readers can tell when it appeared.
    private static func timestampedChunks(parsed p: ParsedVideoMd,
                                          segments rawSegments: [ParsedVideoMd.Segment],
                                          kind: Chunk.Kind,
                                          tokens: TokenCounter) -> [Chunk] {
        guard !rawSegments.isEmpty else { return [] }
        let budget = contentBudget(title: p.title, tokens: tokens)
        let segments = explodeOversizedSegments(rawSegments, target: budget, tokens: tokens)

        var out: [Chunk] = []
        var bucket: [(segment: ParsedVideoMd.Segment, tokens: Int)] = []
        var total = 0
        var hasNew = false

        func flush() {
            guard hasNew, let first = bucket.first, let last = bucket.last else { return }
            let plain = bucket.map(\.segment.text).joined(separator: " ")
            let text = kind == .frameText
                ? bucket.map { "[\(formatTimestamp($0.segment.startMs))] \($0.segment.text)" }.joined(separator: "\n")
                : plain
            out.append(Chunk(type: kind, index: out.count, text: text,
                             embeddingInput: EmbeddingGemma2.documentInput(title: p.title, text: plain),
                             startMs: first.segment.startMs,
                             endMs: last.segment.endMs ?? last.segment.startMs))
            var tail: [(segment: ParsedVideoMd.Segment, tokens: Int)] = []
            var tailTokens = 0
            for item in bucket.reversed() {
                if tailTokens + item.tokens > overlapTokens { break }
                tail.insert(item, at: 0)
                tailTokens += item.tokens
            }
            bucket = tail
            total = tailTokens
            hasNew = false
        }

        for segment in segments {
            let count = tokens(segment.text) + 1
            if hasNew, total + count > budget { flush() }
            bucket.append((segment, count))
            total += count
            hasNew = true
            if total >= budget { flush() }
        }
        flush()
        return out
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

    /// Character-based token estimate for callers without the model tokenizer.
    static func approxTokens(_ s: String) -> Int {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return 0 }
        return max(1, Int(ceil(Double(trimmed.count) / charsPerToken)))
    }

    // MARK: - Splitting (keep every chunk inside the model window)

    /// Split any segment longer than `target` tokens into sentence-grouped
    /// pieces, interpolating timestamps across the segment's span so each piece
    /// still maps to the right frame. Shorter segments pass through untouched.
    private static func explodeOversizedSegments(_ segs: [ParsedVideoMd.Segment],
                                                 target: Int,
                                                 tokens: TokenCounter) -> [ParsedVideoMd.Segment] {
        var out: [ParsedVideoMd.Segment] = []
        for seg in segs {
            if tokens(seg.text) <= target { out.append(seg); continue }
            let pieces = splitText(seg.text, target: target, overlap: 0, tokens: tokens)
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
    /// to word-splitting, so no piece exceeds `target`.
    static func splitText(_ text: String, target: Int, overlap: Int,
                          tokens: TokenCounter = approxTokens) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }
        if tokens(trimmed) <= target { return [trimmed] }

        let sentences = splitIntoSentences(trimmed)
        var pieces: [String] = []
        var cur: [(text: String, tokens: Int)] = []
        var curTok = 0

        func flush(carryOverlap: Bool) {
            guard !cur.isEmpty else { return }
            pieces.append(cur.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespaces))
            guard carryOverlap, overlap > 0 else { cur = []; curTok = 0; return }
            var tail: [(text: String, tokens: Int)] = []
            var t = 0
            for u in cur.reversed() {
                if t + u.tokens > overlap { break }
                tail.insert(u, at: 0); t += u.tokens
            }
            cur = tail; curTok = t
        }

        for unit in sentences {
            let count = tokens(unit) + 1
            if count > target {
                flush(carryOverlap: false)
                pieces.append(contentsOf: wordSplit(unit, target: target, tokens: tokens))
                continue
            }
            if !cur.isEmpty, curTok + count > target { flush(carryOverlap: true) }
            cur.append((unit, count)); curTok += count
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
    /// group words up to `target` tokens.
    private static func wordSplit(_ text: String, target: Int, tokens: TokenCounter) -> [String] {
        let cap = max(target, 1)
        let words = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
        var out: [String] = []
        var cur: [Substring] = []
        var tok = 0
        for w in words {
            let count = tokens(String(w)) + 1
            if !cur.isEmpty, tok + count > cap { out.append(cur.joined(separator: " ")); cur = []; tok = 0 }
            cur.append(w); tok += count
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

    /// "1:23", "1:02:03", or with milliseconds ("0:04.560", the on-device
    /// transcription format) → ms; nil on parse failure.
    static func parseTimestampLabelToMs(_ s: String) -> Int? {
        let parts = s.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard (1...3).contains(parts.count), let last = parts.last,
              last.allSatisfy({ $0.isNumber || $0 == "." }),
              let seconds = Double(last), seconds.isFinite else { return nil }
        var minutes = 0
        for part in parts.dropLast() {
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let value = Int(part) else { return nil }
            minutes = minutes * 60 + value
        }
        return minutes * 60_000 + Int((seconds * 1000).rounded())
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
