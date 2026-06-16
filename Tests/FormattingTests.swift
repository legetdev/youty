import XCTest
@testable import youty

// Pure-logic tests for timestamp + markdown formatting (the cross-platform
// transcript contract). No network, no I/O.

final class TimestampFormattingTests: XCTestCase {

    func testZero() {
        XCTAssertEqual(SpeechTranscriptionPipeline.formatTimestamp(seconds: 0), "0:00.000")
    }

    func testUnderOneMinute() {
        XCTAssertEqual(SpeechTranscriptionPipeline.formatTimestamp(seconds: 7), "0:07.000")
    }

    func testMinutesSeconds() {
        XCTAssertEqual(SpeechTranscriptionPipeline.formatTimestamp(seconds: 65.5), "1:05.500")
    }

    func testOverOneHourSwitchesFormat() {
        XCTAssertEqual(SpeechTranscriptionPipeline.formatTimestamp(seconds: 3661.0), "1:01:01.000")
    }

    func testMillisecondRounding() {
        XCTAssertEqual(SpeechTranscriptionPipeline.formatTimestamp(seconds: 1.2349), "0:01.235")
    }

    func testNegativeClampsToZero() {
        XCTAssertEqual(SpeechTranscriptionPipeline.formatTimestamp(seconds: -5), "0:00.000")
    }

    func testNonFiniteClampsToZero() {
        XCTAssertEqual(SpeechTranscriptionPipeline.formatTimestamp(seconds: .infinity), "0:00.000")
    }
}

final class MarkdownFormattingTests: XCTestCase {

    func testTitleAndBody() {
        let md = TranscriptFetcher.formatMarkdown(title: "My Video", segments: ["hello", "world"])
        XCTAssertEqual(md, "# My Video\n\nhello world\n")
    }

    func testStartsWithHeadingEndsWithNewline() {
        let md = TranscriptFetcher.formatMarkdown(title: "Title", segments: ["a", "b", "c"])
        XCTAssertTrue(md.hasPrefix("# Title\n\n"))
        XCTAssertTrue(md.hasSuffix("\n"))
    }

    func testWrapsAtEightyColumns() {
        // 40 ten-char words → must wrap; no line may exceed 80 columns.
        let words = Array(repeating: "wordwordX0", count: 40)  // 10 chars each
        let md = TranscriptFetcher.formatMarkdown(title: "T", segments: words)
        let body = md.dropFirst("# T\n\n".count)
        for line in body.split(separator: "\n") {
            XCTAssertLessThanOrEqual(line.count, 80, "line exceeded 80 columns: \(line)")
        }
        // And the content is preserved (joining lines back yields the words).
        let rejoined = body.split(separator: "\n").joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(rejoined, words.joined(separator: " "))
    }
}
