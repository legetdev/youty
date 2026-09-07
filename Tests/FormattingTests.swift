import XCTest
import AppKit
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

final class SidxValidationTests: XCTestCase {
    /// Truncated version-specific fields must throw rather than index past Data.
    func testRejectsTruncatedAndUnsupportedHeaders() {
        for version: UInt8 in [0, 1, 2] {
            for length in 12..<40 {
                var data = Data(repeating: 0, count: length)
                data[3] = UInt8(length)
                data.replaceSubrange(4..<8, with: Data("sidx".utf8))
                data[8] = version
                if version == 0 && length >= 32 { continue }
                XCTAssertThrowsError(try SidxParser.parse(headBytes: data))
            }
        }
    }

    /// Bytes from a following MP4 box must not be used to complete this one.
    func testRejectsFieldsOutsideDeclaredBox() {
        var data = Data(repeating: 0, count: 64)
        data[3] = 20
        data.replaceSubrange(4..<8, with: Data("sidx".utf8))
        XCTAssertThrowsError(try SidxParser.parse(headBytes: data))
    }
}

final class VaultPathTests: XCTestCase {
    /// Frame replacement preserves custom files, retires stale frames, and rejects failed captures.
    @MainActor
    func testFrameReplacementPreservesBundleData() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("youtube/Test")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let note = "---\nvideo_id: example\nplatform: youtube\n---\nOriginal transcript"
        try note.write(to: folder.appendingPathComponent("video.md"), atomically: true, encoding: .utf8)
        try Data("custom".utf8).write(to: folder.appendingPathComponent("custom.txt"))
        try Data("old frame".utf8).write(to: folder.appendingPathComponent("00000000.jpg"))
        let vault = VaultManager()
        vault.vaultURL = root
        XCTAssertThrowsError(try vault.writeFrames([], to: folder))
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("00000000.jpg"), encoding: .utf8), "old frame")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 32, bitsPerPixel: 32))
        let pixels = try XCTUnwrap(bitmap.bitmapData)
        pixels.initialize(repeating: 255, count: 8 * 32)
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.addRepresentation(bitmap)
        try vault.writeFrames([FrameExtractor.Frame(timestamp: 1, image: image)], to: folder)
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("video.md"), encoding: .utf8), note)
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("custom.txt"), encoding: .utf8), "custom")
        XCTAssertFalse(fm.fileExists(atPath: folder.appendingPathComponent("00000000.jpg").path))
        XCTAssertNotNil(NSImage(contentsOf: folder.appendingPathComponent("00001000.jpg")))
    }

    /// Missing roots must not look like an empty, successfully scanned vault.
    func testIndexerRejectsUnavailableVault() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(try Indexer.enumerateBundles(at: missing))
    }
    /// A failed staged commit leaves the old bundle available; a successful one replaces it.
    func testBundleCommitPreservesOldDataUntilSuccess() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let destination = root.appendingPathComponent("saved")
        let staged = root.appendingPathComponent("staged")
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let oldNote = destination.appendingPathComponent("video.md")
        try Data("original".utf8).write(to: oldNote)
        XCTAssertThrowsError(try VaultManager.commitBundle(staged: staged, to: destination))
        XCTAssertEqual(try String(contentsOf: oldNote, encoding: .utf8), "original")
        try fm.createDirectory(at: staged, withIntermediateDirectories: true)
        try Data("replacement".utf8).write(to: staged.appendingPathComponent("video.md"))
        try VaultManager.commitBundle(staged: staged, to: destination)
        XCTAssertEqual(try String(contentsOf: oldNote, encoding: .utf8), "replacement")
        XCTAssertFalse(fm.fileExists(atPath: staged.path))
    }

    /// Staging is excluded without hiding genuine dot-prefixed platform or legacy bundles.
    func testTitleCollisionsAndHiddenStaging() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let existing = root.appendingPathComponent("youtube/Channel - Title")
        let hidden = root.appendingPathComponent("youtube/.youty-save-test")
        let hiddenFrames = root.appendingPathComponent("youtube/.youty-frames-test")
        let dotChannel = root.appendingPathComponent("youtube/.NET - Tutorial")
        let dotLegacy = root.appendingPathComponent(".Legacy Tutorial")
        defer { try? fm.removeItem(at: root) }
        let note = "---\nvideo_id: first\nplatform: youtube\ntitle: Test\n---\n"
        for bundle in [existing, hidden, hiddenFrames, dotChannel, dotLegacy] {
            try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
            try note.write(to: bundle.appendingPathComponent("video.md"), atomically: true, encoding: .utf8)
        }
        XCTAssertEqual(try VaultManager.destinationBundle(in: root, platform: "youtube", name: "Channel - Title", videoID: "first").path, existing.path)
        let second = try VaultManager.destinationBundle(in: root, platform: "youtube", name: "Channel - Title", videoID: "second")
        XCTAssertNotEqual(second, existing)
        XCTAssertEqual(second.lastPathComponent, "Channel - Title - second")
        VaultManager.writeManifest(in: root)
        let entries = try JSONDecoder().decode([VaultManager.ManifestEntry].self,
            from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        XCTAssertEqual(Set(entries.map(\.folder)), ["youtube/Channel - Title", "youtube/.NET - Tutorial", ".Legacy Tutorial"])
        let indexedPaths = try Indexer.enumerateBundles(at: root).map { $0.deletingLastPathComponent().lastPathComponent }
        XCTAssertEqual(Set(indexedPaths), ["Channel - Title", ".NET - Tutorial", ".Legacy Tutorial"])
    }

    /// A manifest path cannot resolve to the vault itself or anything outside it.
    func testRejectsEscapesAndPlatformRoots() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vault")
        for path in ["", ".", "..", "../outside", "/tmp/outside", "youtube", "youtube/..", "youtube/../../outside"] {
            XCTAssertNil(VaultManager.bundleURL(relativePath: path, in: root), path)
        }
        XCTAssertNotNil(VaultManager.bundleURL(relativePath: "youtube/Title.. continued", in: root))
        XCTAssertNotNil(VaultManager.bundleURL(relativePath: "Legacy Bundle", in: root))
    }

    /// A lexically safe path is still unsafe when a platform folder is a symlink.
    func testRejectsSymlinkEscape() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createSymbolicLink(at: root.appendingPathComponent("youtube"), withDestinationURL: fm.temporaryDirectory)
        XCTAssertNil(VaultManager.bundleURL(relativePath: "youtube/outside", in: root))
    }
}

final class FrameInputValidationTests: XCTestCase {
    /// Invalid preferences and non-finite media durations cannot trap integer conversions.
    func testInvalidSamplingInputs() {
        XCTAssertTrue(FrameExtractor.frameTimes(duration: .infinity).isEmpty)
        XCTAssertTrue(FrameExtractor.frameTimes(duration: 10, countCap: -1).isEmpty)
        XCTAssertTrue(FrameExtractor.frameTimes(duration: 10, fpsCap: .nan).isEmpty)
        XCTAssertEqual(FrameExtractor.frameTimes(duration: 10, countCap: 500, fpsCap: .greatestFiniteMagnitude).count, 500)
        XCTAssertEqual(FrameExtractor.frameTimes(duration: 1000, countCap: 750, fpsCap: 1).count, 750)
    }

    /// Empty and oversized box headers must fail without pointer reads or integer traps.
    func testMalformedMoofHeaders() {
        XCTAssertThrowsError(try MP4MoofParser.parse(segmentData: Data(), segmentStartInFile: 0))
        let oversized = Data([0, 0, 0, 8, 102, 114, 101, 101, 0, 0, 0, 1, 109, 111, 111, 102,
                              127, 255, 255, 255, 255, 255, 255, 255])
        XCTAssertThrowsError(try MP4MoofParser.parse(segmentData: oversized, segmentStartInFile: 0))
    }
}
