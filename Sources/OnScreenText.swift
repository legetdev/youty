import Foundation

/// Bridges OCR (`FrameOCR`) to the vault: idempotently writes an
/// "## On-screen text" section into a bundle's `video.md` so the recognized
/// on-screen text becomes part of the user-owned artifact and flows through the
/// normal chunk → embed → search pipeline (as `frame_text` chunks).
///
/// Keeping the text *in video.md* (not only in the index) preserves Youty's core
/// invariant — the index is rebuildable from the vault alone — so a re-index
/// never loses the OCR layer, and the user can read/grep/version it like
/// everything else. One hook covers both new saves and re-indexing of existing
/// vaults, because both run through `Indexer.indexBundle`.
enum OnScreenText {

    static let heading = "## On-screen text"
    /// Marks sections written by the current filter (chrome + novelty dedupe).
    /// A section without it predates those filters and is regenerated once.
    static let versionMarker = "<!-- youty:on-screen-text v2 -->"

    /// Add the on-screen-text section to `folder`'s video.md if it isn't there
    /// yet, or replace one written by an older filter. No-op when disabled,
    /// already current, or no frames exist on disk yet (so a save that indexes
    /// text before frames are written can still add it on the next index).
    /// Returns true iff it wrote the file.
    @discardableResult
    static func ensureSection(inBundle folder: URL, enabled: Bool) -> Bool {
        guard enabled else { return false }
        let mdURL = folder.appendingPathComponent("video.md")
        guard let original = try? String(contentsOf: mdURL, encoding: .utf8) else { return false }
        if isCurrent(original) { return false }                     // already done — idempotent
        guard FrameOCR.hasFrames(in: folder) else { return false }  // frames not ready yet
        let md = removingSection(from: original)

        // Title / channel / transcript power the noise filters (watermark drop,
        // burned-in-caption dedup).
        guard let parsed = try? Chunker.parse(text: md) else { return false }
        let transcript = parsed.segments.map { $0.text }.joined(separator: " ")
        let entries = FrameOCR.onScreenText(forFrameDir: folder,
                                            transcript: transcript,
                                            title: parsed.title,
                                            channel: parsed.channel)

        // Even when OCR finds nothing, write a placeholder so we don't re-OCR
        // every index. The `_`-prefixed line is skipped by the chunk parser, so
        // it yields no chunks — it's purely the "already processed" marker.
        let body: String
        if entries.isEmpty {
            body = "_No on-screen text detected._"
        } else {
            body = entries.map { "[\(label($0.ms))] \(sanitize($0.text))" }.joined(separator: "\n")
        }
        let section = "\n\(heading)\n\(versionMarker)\n\n\(body)\n"
        let updated = (md.hasSuffix("\n") ? md : md + "\n") + section
        do {
            try updated.write(to: mdURL, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    /// True when `md` already carries a section written by the current filter.
    static func isCurrent(_ md: String) -> Bool {
        md.contains(heading) && md.contains(versionMarker)
    }

    /// `md` without its on-screen-text section (heading through the next `## `
    /// heading or end of file); other sections are preserved byte for byte.
    static func removingSection(from md: String) -> String {
        var lines = md.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == heading })
        else { return md }
        let end = lines[(start + 1)...].firstIndex(where: { $0.hasPrefix("## ") }) ?? lines.count
        lines.removeSubrange(start..<end)
        var head = Array(lines[..<start])
        let tail = Array(lines[start...])
        while let last = head.last, last.trimmingCharacters(in: .whitespaces).isEmpty { head.removeLast() }
        return (head + [""] + tail).joined(separator: "\n")
    }

    // MARK: - Formatting

    private static func label(_ ms: Int) -> String {
        let s = ms / 1000, h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                     : String(format: "%d:%02d", m, sec)
    }

    /// Collapse to a single line so it parses as one `[mm:ss] text` entry.
    private static func sanitize(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " · ")
            .trimmingCharacters(in: .whitespaces)
    }
}
