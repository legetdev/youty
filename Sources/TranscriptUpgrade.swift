import Foundation

/// Replaces on-device transcripts of YouTube videos with YouTube's captions
/// once they exist. A video saved within hours of its upload often has no
/// captions yet, so it was transcribed from its audio; YouTube adds automatic
/// captions later. Runs on launch, before the index is reconciled, which then
/// re-indexes every note this rewrote (its file is newer than its index entry).
enum TranscriptUpgrade {

    /// Each video is asked about at most this often, and given up on after
    /// `giveUpAfter` (a video without captions by then won't get them).
    static let recheckAfter: TimeInterval = 6 * 3600
    static let giveUpAfter: TimeInterval = 30 * 24 * 3600
    private static let checkedKey = "captionUpgradeChecked"

    /// Returns how many notes now carry YouTube's captions.
    @discardableResult
    static func run(vaultRoot: URL, now: Date = Date(),
                    captions: (String) async -> [TranscriptSegment]? = { try? await YouTubeCaptions.transcript(videoID: $0) }) async -> Int {
        var checked = UserDefaults.standard.dictionary(forKey: checkedKey) as? [String: Date] ?? [:]
        var upgraded = 0
        for url in (try? Indexer.enumerateBundles(at: vaultRoot)) ?? [] {
            guard let note = try? String(contentsOf: url, encoding: .utf8),
                  let videoID = candidate(note, savedBefore: now.addingTimeInterval(-giveUpAfter)) else { continue }
            if let last = checked[videoID], now.timeIntervalSince(last) < recheckAfter { continue }
            checked[videoID] = now
            guard let segments = await captions(videoID), let updated = replacingTranscript(in: note, with: segments)
            else { continue }
            do {
                try updated.write(to: url, atomically: true, encoding: .utf8)
                checked[videoID] = nil
                upgraded += 1
            } catch {
                DebugLog.log("caption upgrade: couldn't write \(url.path): \(error.localizedDescription)")
            }
        }
        UserDefaults.standard.set(checked.filter { now.timeIntervalSince($0.value) < giveUpAfter }, forKey: checkedKey)
        if upgraded > 0 { _ = VaultManager.rebuildManifest(at: vaultRoot) }
        return upgraded
    }

    /// The video id of a YouTube note transcribed on-device and saved after
    /// `cutoff`, or nil when the note doesn't qualify.
    static func candidate(_ note: String, savedBefore cutoff: Date) -> String? {
        guard let front = frontmatter(note), front["platform"] == "youtube",
              front["transcript_source"] == "on-device speech recognition",
              let videoID = front["video_id"], !videoID.isEmpty else { return nil }
        if let saved = front["date_saved"].flatMap({ ISO8601DateFormatter().date(from: $0) }), saved < cutoff {
            return nil
        }
        return videoID
    }

    /// The note with YouTube's captions as its transcript and without the
    /// on-device marker; every other section (on-screen text, description) stays.
    static func replacingTranscript(in note: String, with segments: [TranscriptSegment]) -> String? {
        guard !segments.isEmpty else { return nil }
        var lines = note.components(separatedBy: "\n")
        guard let heading = lines.firstIndex(of: "## Transcript") else { return nil }
        let end = lines[(heading + 1)...].firstIndex(where: { $0.hasPrefix("## ") }) ?? lines.count
        let body = segments.map { "[\($0.timestamp)] \($0.text)" }
        lines.replaceSubrange(heading..<end, with: ["## Transcript", ""] + body + (end < lines.count ? [""] : []))
        if let marker = lines.firstIndex(of: "transcript_source: on-device speech recognition") {
            lines.remove(at: marker)
        }
        var text = lines.joined(separator: "\n")
        if !text.hasSuffix("\n") { text += "\n" }
        return text
    }

    private static func frontmatter(_ note: String) -> [String: String]? {
        let lines = note.components(separatedBy: "\n")
        guard lines.first == "---", let close = lines.dropFirst().firstIndex(of: "---") else { return nil }
        var fields: [String: String] = [:]
        for line in lines[1..<close] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            fields[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return fields
    }
}
