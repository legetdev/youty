import XCTest
@testable import youty

// Pure-logic tests for what the indexer stores: timestamps, chunk sizing,
// tag hygiene, on-screen text sections, and frame/audio input preparation.
// No models, no network, no index database.

final class TimestampParsingTests: XCTestCase {

    func testWholeSecondLabels() {
        XCTAssertEqual(Chunker.parseTimestampLabelToMs("7:18"), 438_000)
        XCTAssertEqual(Chunker.parseTimestampLabelToMs("1:02:03"), 3_723_000)
    }

    func testOnDeviceTranscriptionLabels() {
        // Instagram/TikTok notes carry milliseconds; these were once dropped.
        XCTAssertEqual(Chunker.parseTimestampLabelToMs("0:04.560"), 4_560)
        XCTAssertEqual(Chunker.parseTimestampLabelToMs("1:00:00.250"), 3_600_250)
    }

    func testRejectsMalformedLabels() {
        XCTAssertNil(Chunker.parseTimestampLabelToMs("ab:12"))
        XCTAssertNil(Chunker.parseTimestampLabelToMs("1:2:3:4"))
        XCTAssertNil(Chunker.parseTimestampLabelToMs("-1:00"))
    }
}

final class ChunkingTests: XCTestCase {

    private func note(lines: Int, extraSections: String = "") -> String {
        let transcript = (0..<lines).map { i in
            "[\(i / 60):\(String(format: "%02d", i % 60))] sentence \(i) explains how attention averages earlier tokens"
        }.joined(separator: "\n")
        return """
        ---
        title: "\\"Let's build\\" GPT"
        platform: youtube
        video_id: kCc8FmEb1nY
        channel: "Andrej Karpathy"
        tags: ["gpt", "um", "transformer, part 2"]
        ---

        ## Transcript

        \(transcript)
        \(extraSections)
        """
    }

    func testChunksStayInsideTheModelWindow() throws {
        let parsed = try Chunker.parse(text: note(lines: 400))
        let chunks = Chunker.chunk(parsed: parsed)
        let body = chunks.filter { $0.type == .body }
        XCTAssertGreaterThan(body.count, 5)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(Chunker.approxTokens(chunk.embeddingInput), Chunker.maxInputTokens)
            XCTAssertTrue(chunk.embeddingInput.hasPrefix(#"title: "Let's build" GPT | text: "#))
        }
        // Consecutive chunks share a short overlap and keep increasing times.
        for (a, b) in zip(body, body.dropFirst()) {
            XCTAssertLessThan(a.startMs!, b.startMs!)
            XCTAssertLessThanOrEqual(b.startMs!, a.endMs!)
        }
    }

    func testSpokenChunksAreProseAndHeaderDropsFiller() throws {
        let parsed = try Chunker.parse(text: note(lines: 10))
        let chunks = Chunker.chunk(parsed: parsed)
        let header = try XCTUnwrap(chunks.first { $0.type == .header })
        XCTAssertTrue(header.text.contains("Topics: gpt, transformer"))
        XCTAssertFalse(header.text.contains("um"))
        let body = try XCTUnwrap(chunks.first { $0.type == .body })
        XCTAssertFalse(body.text.contains("[0:"), "spoken chunks are stored as prose")
    }

    func testShortFormTranscriptsProduceSpokenChunks() throws {
        let raw = """
        ---
        title: "Reel"
        platform: instagram
        post_id: "ABC"
        ---

        ## Transcript

        [0:00.000] Create AI influencers easily
        [0:04.560] with our platform
        """
        let chunks = Chunker.chunk(parsed: try Chunker.parse(text: raw))
        let body = try XCTUnwrap(chunks.first { $0.type == .body })
        XCTAssertEqual(body.startMs, 0)
        XCTAssertTrue(body.text.contains("with our platform"))
    }
}

final class FrontmatterTests: XCTestCase {

    func testQuotedValuesAreUnescaped() {
        XCTAssertEqual(Chunker.frontmatterScalar(#""\"Hi\" — a \\ b""#), #""Hi" — a \ b"#)
        XCTAssertEqual(Chunker.frontmatterScalar("youtube"), "youtube")
        XCTAssertEqual(Chunker.frontmatterList(#"["a, b", "c"]"#), ["a, b", "c"])
        XCTAssertEqual(Chunker.frontmatterList("[a, b]"), ["a", "b"])
    }
}

final class TagCleaningTests: XCTestCase {

    func testRemovesFillerFragmentsAndDuplicates() {
        XCTAssertEqual(Tags.clean(["AI", "um", "äh die Bundesregierung", "ai", "413", "äh", "Claude Code"]),
                       ["ai", "die bundesregierung", "claude code"])
    }
}

final class OnScreenTextSectionTests: XCTestCase {

    func testOutdatedSectionIsReplacedNotDuplicated() {
        let old = "---\ntitle: x\n---\n\n## Transcript\n\n[0:00] hi\n\n## On-screen text\n\n[0:01] Chrome · History\n"
        XCTAssertFalse(OnScreenText.isCurrent(old))
        let stripped = OnScreenText.removingSection(from: old)
        XCTAssertEqual(stripped, "---\ntitle: x\n---\n\n## Transcript\n\n[0:00] hi\n")
    }

    func testSectionInTheMiddleKeepsFollowingSections() {
        let md = "## Transcript\n\n[0:00] hi\n\n## On-screen text\n\n[0:01] x\n\n## Notes\n\nkeep me\n"
        XCTAssertEqual(OnScreenText.removingSection(from: md), "## Transcript\n\n[0:00] hi\n\n## Notes\n\nkeep me\n")
    }
}

final class ModelInputTests: XCTestCase {

    func testFrameSizingMatchesGemma4Processor() {
        // Same results as transformers' get_aspect_ratio_preserving_size.
        XCTAssertEqual(EmbeddingGemma2.targetSize(height: 1080, width: 1920, maxPatches: 2520).height, 576)
        XCTAssertEqual(EmbeddingGemma2.targetSize(height: 1080, width: 1920, maxPatches: 2520).width, 1056)
        XCTAssertEqual(EmbeddingGemma2.targetSize(height: 1280, width: 720, maxPatches: 2520).height, 1056)
        XCTAssertEqual(EmbeddingGemma2.targetSize(height: 1280, width: 720, maxPatches: 2520).width, 576)
    }

    func testDocumentInputUsesTheTitleSlot() {
        XCTAssertEqual(EmbeddingGemma2.documentInput(title: "A | B\nC", text: "body"), "title: A / B C | text: body")
        XCTAssertEqual(EmbeddingGemma2.documentInput(title: " ", text: "body"), "title: none | text: body")
    }

    func testPicksSmallestDirectAudioStream() {
        let formats: [[String: Any]] = [
            ["mimeType": "video/mp4; codecs=\"avc1\"", "url": "https://v/1", "contentLength": "100", "bitrate": 1],
            ["mimeType": "audio/mp4; codecs=\"mp4a.40.2\"", "url": "https://a/140", "contentLength": "3000", "bitrate": 128_000],
            ["mimeType": "audio/mp4; codecs=\"mp4a.40.5\"", "url": "https://a/139", "contentLength": "1200", "bitrate": 48_000],
            ["mimeType": "audio/webm; codecs=\"opus\"", "url": "https://a/251", "contentLength": "900", "bitrate": 30_000],
            ["mimeType": "audio/mp4; codecs=\"mp4a.40.2\"", "signatureCipher": "s=…", "contentLength": "800", "bitrate": 10_000],
        ]
        let picked = YouTubeAudioTranscript.smallestAudio(in: formats)
        XCTAssertEqual(picked?.url.absoluteString, "https://a/139")
        XCTAssertEqual(picked?.length, 1200)
    }

    func testPostLanguageGuidesAutomaticTranscription() {
        XCTAssertEqual(SpeechTranscriptionPipeline.detectedLocale(in: "Step by step wie man 10k im Monat mit Claude Code macht")?.identifier, "de")
        XCTAssertNil(SpeechTranscriptionPipeline.detectedLocale(in: "ok"))
    }
}
