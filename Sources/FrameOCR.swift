import Foundation
import Vision
import ImageIO
import CoreGraphics

/// On-device OCR of saved video frames via Apple's Vision framework. Turns the
/// text shown *on screen* — slides, code, terminal output, chart labels, tool
/// names — into searchable content, complementing the spoken transcript and the
/// SigLIP visual index. No network, no key, nothing leaves the Mac: it runs at
/// index time over the full-resolution frame JPEGs already on disk.
enum FrameOCR {

    /// Minimum recognition confidence to keep a line (Vision returns 0…1).
    /// Modest on purpose — slide/code text is usually crisp, and the downstream
    /// noise filters (transcript dedup, watermark drop) catch the rest.
    private static let minConfidence: Float = 0.4
    /// Drop recognized lines shorter than this (logos, stray glyphs).
    private static let minLineChars = 3

    /// True if `folder` holds at least one `NNNNNNNN.jpg` frame — used to avoid
    /// writing an "empty" section before frames have actually been extracted.
    static func hasFrames(in folder: URL) -> Bool { !frameFiles(in: folder).isEmpty }

    /// OCR every `NNNNNNNN.jpg` frame in `folder` and return timestamped,
    /// de-noised on-screen text. Lines already in the spoken `transcript`
    /// (burned-in captions) or equal to the title/channel watermark are dropped,
    /// and a frame whose text repeats the previous kept frame (a held slide) is
    /// skipped — so the result is the *changes* in on-screen text over time, not
    /// one entry per identical frame.
    static func onScreenText(forFrameDir folder: URL,
                             transcript: String,
                             title: String,
                             channel: String) -> [(ms: Int, text: String)] {
        let frames = frameFiles(in: folder)
        guard !frames.isEmpty else { return [] }

        let transcriptNorm = normalize(transcript)
        var stop = Set<String>()
        for s in [normalize(title), normalize(channel)] where !s.isEmpty { stop.insert(s) }

        // Only OCR visually-distinct frames — skip held slides / static UI so we
        // don't pay Vision (the bottleneck) for near-identical frames, nor emit a
        // redundant chunk per repeated screen. Motion-heavy video keeps most
        // frames (they genuinely differ). Reuses the same feature-print dedup the
        // frame embedder uses.
        let distinct = PHashFilter.keepIndices(jpegURLs: frames.map { $0.url }).map { frames[$0] }

        // Each frame is independent; recognize concurrently, then do the
        // order-dependent dedup pass single-threaded below. Results go to
        // pre-allocated slots under a lock (Array isn't safe for unsynchronized
        // concurrent writes even to distinct indices).
        var perFrameLines = [[String]](repeating: [], count: distinct.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: distinct.count) { i in
            guard let cg = loadCGImage(distinct[i].url) else { return }
            let lines = recognizeLines(in: cg)
            lock.lock(); perFrameLines[i] = lines; lock.unlock()
        }

        var out: [(ms: Int, text: String)] = []
        var lastKeptNorm = ""
        for (i, frame) in distinct.enumerated() {
            let ms = frame.ms
            let kept = perFrameLines[i].filter { line in
                let n = normalize(line)
                if n.count < minLineChars { return false }
                if stop.contains(n) { return false }                       // watermark / channel bug
                if !transcriptNorm.isEmpty && transcriptNorm.contains(n) { return false }  // burned-in caption
                return true
            }
            guard !kept.isEmpty else { continue }
            let joined = kept.joined(separator: " · ")
            let joinedNorm = normalize(joined)
            if joinedNorm == lastKeptNorm { continue }   // held slide — skip the repeat
            lastKeptNorm = joinedNorm
            out.append((ms: ms, text: joined))
        }
        return out
    }

    // MARK: - Vision

    private static func recognizeLines(in cgImage: CGImage) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do { try handler.perform([request]) } catch { return [] }
        var lines: [String] = []
        for o in request.results ?? [] {
            guard let top = o.topCandidates(1).first, top.confidence >= minConfidence else { continue }
            let s = top.string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { lines.append(s) }
        }
        return lines
    }

    // MARK: - Helpers

    /// `(ms, url)` for every `NNNNNNNN.jpg` in the folder, sorted by timestamp.
    private static func frameFiles(in folder: URL) -> [(ms: Int, url: URL)] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil) else { return [] }
        var out: [(Int, URL)] = []
        for u in items where u.pathExtension.lowercased() == "jpg" {
            let stem = u.deletingPathExtension().lastPathComponent
            if !stem.isEmpty, stem.allSatisfy({ $0.isNumber }), let ms = Int(stem) {
                out.append((ms, u))
            }
        }
        return out.sorted { $0.0 < $1.0 }.map { (ms: $0.0, url: $0.1) }
    }

    private static func loadCGImage(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// Lowercased, whitespace-collapsed form for dedup/containment comparisons.
    private static func normalize(_ s: String) -> String {
        s.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
