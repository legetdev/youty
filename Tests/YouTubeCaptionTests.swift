import XCTest
@testable import youty

// A YouTube transcript must come from YouTube's captions whenever they exist,
// in the language actually spoken, and the on-device fallback must listen to
// the original audio, never an AI dub. Shapes mirror the player API's answer
// for a dubbed video (yt:C0jOKDJtK9s), whose smallest audio stream is Korean.

final class YouTubeCaptionTrackTests: XCTestCase {

    private func audio(_ itag: Int, bitrate: Int, track: (id: String, isDefault: Bool)? = nil) -> [String: Any] {
        var format: [String: Any] = ["itag": itag, "mimeType": "audio/mp4; codecs=\"mp4a.40.5\"", "bitrate": bitrate,
                                     "url": "https://example.com/\(itag)-\(track?.id ?? "only")", "contentLength": "1000"]
        if let track { format["audioTrack"] = ["id": track.id, "audioIsDefault": track.isDefault] }
        return format
    }

    private func caption(_ language: String, automatic: Bool = true) -> [String: Any] {
        var track: [String: Any] = ["languageCode": language, "baseUrl": "https://www.youtube.com/api/timedtext?v=x&lang=\(language)&fmt=srv3"]
        if automatic { track["kind"] = "asr" }
        return track
    }

    func testFallbackAudioIsTheOriginalNotASmallerDub() {
        let formats = [audio(139, bitrate: 52_333, track: ("ko.10", false)),
                       audio(139, bitrate: 52_800, track: ("en-US.4", true)),
                       audio(140, bitrate: 129_000, track: ("en-US.4", true))]
        XCTAssertEqual(YouTubeAudioTranscript.smallestAudio(in: formats)?.url.absoluteString,
                       "https://example.com/139-en-US.4")
    }

    func testFallbackAudioWithoutDubsIsTheSmallest() {
        let formats = [audio(140, bitrate: 129_000), audio(139, bitrate: 48_000)]
        XCTAssertEqual(YouTubeAudioTranscript.smallestAudio(in: formats)?.url.absoluteString, "https://example.com/139-only")
    }

    func testOriginalLanguageComesFromTheDefaultAudio() {
        let formats = [audio(139, bitrate: 1, track: ("ko.10", false)), audio(139, bitrate: 2, track: ("en-US.4", true))]
        XCTAssertEqual(YouTubeCaptions.originalLanguage(in: formats), "en")
        XCTAssertNil(YouTubeCaptions.originalLanguage(in: [audio(140, bitrate: 1)]))
    }

    func testDubbedVideoGetsCaptionsInTheSpokenLanguage() {
        let tracks = ["nl", "en", "fr", "de", "ko"].map { caption($0) }
        XCTAssertEqual(YouTubeCaptions.bestTrack(tracks, spoken: "en")?["languageCode"] as? String, "en")
    }

    func testCreatorCaptionsBeatAutomaticOnes() {
        let tracks = [caption("de"), caption("de", automatic: false), caption("en", automatic: false)]
        let best = YouTubeCaptions.bestTrack(tracks, spoken: "de")
        XCTAssertEqual(best?["languageCode"] as? String, "de")
        XCTAssertNil(best?["kind"])
    }

    func testTheOnlyAutomaticTrackNamesTheSpokenLanguage() {
        let tracks = [caption("en", automatic: false), caption("de")]
        XCTAssertEqual(YouTubeCaptions.bestTrack(tracks, spoken: nil)?["languageCode"] as? String, "de")
    }

    func testUnknownLanguageFallsBackSensibly() {
        XCTAssertEqual(YouTubeCaptions.bestTrack([caption("nl"), caption("en")], spoken: nil)?["languageCode"] as? String, "en")
        XCTAssertNil(YouTubeCaptions.bestTrack([], spoken: "en"))
    }

    func testCaptionURLAsksForJSON3() throws {
        let url = try XCTUnwrap(YouTubeCaptions.json3URL(caption("en")))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.filter { $0.name == "fmt" }.map(\.value), ["json3"])
        XCTAssertEqual(items.first { $0.name == "lang" }?.value, "en")
    }

    func testJSON3CuesBecomeTimestampedSegments() {
        let json = """
        {"wireMagic":"pb3","events":[
          {"tStartMs":0,"dDurationMs":4000,"segs":[{"utf8":"Oh my god,"},{"utf8":" Opus","tOffsetMs":400},{"utf8":" is incredible"}]},
          {"tStartMs":2000,"aAppend":1,"segs":[{"utf8":"\\n"}]},
          {"tStartMs":256440,"segs":[{"utf8":"So, every time a new AI model\\ncomes out"}]},
          {"tStartMs":3725000,"segs":[{"utf8":"Thank you so much for watching"}]},
          {"tStartMs":3800000}
        ]}
        """
        let segments = YouTubeCaptions.segments(json3: Data(json.utf8))
        XCTAssertEqual(segments.map(\.text), ["Oh my god, Opus is incredible",
                                              "So, every time a new AI model comes out",
                                              "Thank you so much for watching"])
        XCTAssertEqual(segments.map(\.timestamp), ["0:00", "4:16", "1:02:05"])
        XCTAssertTrue(YouTubeCaptions.segments(json3: Data("not json".utf8)).isEmpty)
    }
}

final class TranscriptUpgradeTests: XCTestCase {

    private let note = """
    ---
    title: "Video"
    platform: youtube
    video_id: C0jOKDJtK9s
    date_saved: 2026-10-31T17:19:46Z
    transcript_source: on-device speech recognition
    ---

    ## Description

    Hey friends.

    ## Transcript

    [4:16.440] AI, yong, sang, sang.
    [4:26.760] , , , , ,

    ## On-screen text
    <!-- youty:on-screen-text v2 -->
    [0:55] The challenge

    """

    private let captions = [TranscriptSegment(text: "Oh my god", timestamp: "0:00"),
                            TranscriptSegment(text: "So, every time", timestamp: "0:32")]

    func testOnlyRecentOnDeviceYouTubeNotesQualify() {
        let saved = ISO8601DateFormatter().date(from: "2026-10-31T17:19:46Z")!
        XCTAssertEqual(TranscriptUpgrade.candidate(note, savedBefore: saved.addingTimeInterval(-60)), "C0jOKDJtK9s")
        XCTAssertNil(TranscriptUpgrade.candidate(note, savedBefore: saved.addingTimeInterval(60)))
        XCTAssertNil(TranscriptUpgrade.candidate(note.replacingOccurrences(of: "transcript_source: on-device speech recognition\n", with: ""),
                                                 savedBefore: .distantPast))
        XCTAssertNil(TranscriptUpgrade.candidate(note.replacingOccurrences(of: "platform: youtube", with: "platform: tiktok"),
                                                 savedBefore: .distantPast))
    }

    func testCaptionsReplaceOnlyTheTranscript() throws {
        let updated = try XCTUnwrap(TranscriptUpgrade.replacingTranscript(in: note, with: captions))
        XCTAssertEqual(updated, """
        ---
        title: "Video"
        platform: youtube
        video_id: C0jOKDJtK9s
        date_saved: 2026-10-31T17:19:46Z
        ---

        ## Description

        Hey friends.

        ## Transcript

        [0:00] Oh my god
        [0:32] So, every time

        ## On-screen text
        <!-- youty:on-screen-text v2 -->
        [0:55] The challenge

        """)
        let parsed = try Chunker.parse(text: updated)
        XCTAssertEqual(parsed.segments.count, 2)
        XCTAssertNil(TranscriptUpgrade.replacingTranscript(in: note, with: []))
    }

    func testTranscriptAsTheLastSection() throws {
        let last = "---\nplatform: youtube\n---\n\n## Transcript\n\n[0:01] noise\n"
        XCTAssertEqual(TranscriptUpgrade.replacingTranscript(in: last, with: captions),
                       "---\nplatform: youtube\n---\n\n## Transcript\n\n[0:00] Oh my god\n[0:32] So, every time\n")
    }

    func testRunUpgradesTheVaultAndAsksAtMostEverySixHours() async throws {
        let vault = FileManager.default.temporaryDirectory.appendingPathComponent("upgrade-\(UUID().uuidString)")
        let bundle = vault.appendingPathComponent("youtube/Ali - Video")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vault) }
        let file = bundle.appendingPathComponent("video.md")
        try note.write(to: file, atomically: true, encoding: .utf8)
        UserDefaults.standard.removeObject(forKey: "captionUpgradeChecked")
        defer { UserDefaults.standard.removeObject(forKey: "captionUpgradeChecked") }
        let now = ISO8601DateFormatter().date(from: "2026-10-31T19:00:00Z")!

        var asked = 0
        let none: (String) async -> [TranscriptSegment]? = { _ in asked += 1; return nil }
        let upgradedEarly = await TranscriptUpgrade.run(vaultRoot: vault, now: now, captions: none)
        let recheckedTooSoon = await TranscriptUpgrade.run(vaultRoot: vault, now: now.addingTimeInterval(3600), captions: none)
        XCTAssertEqual([upgradedEarly, recheckedTooSoon, asked], [0, 0, 1])

        let found: (String) async -> [TranscriptSegment]? = { [captions] id in id == "C0jOKDJtK9s" ? captions : nil }
        let upgraded = await TranscriptUpgrade.run(vaultRoot: vault, now: now.addingTimeInterval(7 * 3600), captions: found)
        XCTAssertEqual(upgraded, 1)
        let saved = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(saved.contains("[0:00] Oh my god"))
        XCTAssertFalse(saved.contains("on-device speech recognition"))
        XCTAssertFalse(saved.contains("yong"))
        let again = await TranscriptUpgrade.run(vaultRoot: vault, now: now.addingTimeInterval(14 * 3600), captions: found)
        XCTAssertEqual(again, 0)
    }
}
