import Foundation
import Vision
import ImageIO
import CoreGraphics

/// On-device OCR of saved video frames via Apple's Vision framework. Turns the
/// text shown *on screen* — slides, code, terminal output, chart labels, tool
/// names — into searchable content, complementing the spoken transcript and the
/// visual index. No network, no key, nothing leaves the Mac: it runs at
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
    /// (burned-in captions), equal to the title/channel watermark, or repeated
    /// across a large share of frames (interface chrome) are dropped, and each
    /// kept frame lists only lines that are new since the last few frames — so
    /// the result is the *changes* in on-screen text over time.
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

        // Each frame is independent; recognize concurrently into pre-allocated
        // slots, then run the order-dependent filters single-threaded below.
        let perFrameLines = LineSlots(count: distinct.count)
        DispatchQueue.concurrentPerform(iterations: distinct.count) { i in
            autoreleasepool {   // concurrentPerform doesn't drain per iteration
                guard let cg = loadCGImage(distinct[i].url) else { return }
                perFrameLines.set(i, recognizeLines(in: cg))
            }
        }
        let candidates: [[(raw: String, norm: String)]] = (0..<distinct.count).map { i in
            perFrameLines.get(i).compactMap { line in
                let n = normalize(line)
                if n.count < minLineChars || n.filter(\.isLetter).count < minLineChars { return nil }
                if stop.contains(n) { return nil }                                    // watermark / channel bug
                if !transcriptNorm.isEmpty && transcriptNorm.contains(n) { return nil } // burned-in caption
                return (line, n)
            }
        }

        // Interface chrome (browser menus, tab strips, menu-bar clocks) repeats
        // across most frames of a screen recording and drowns the useful text,
        // so a line seen in a large share of frames is chrome, not content.
        let framesWithText = candidates.filter { !$0.isEmpty }.count
        var frequency: [String: Int] = [:]
        for frame in candidates { for n in Set(frame.map(\.norm)) { frequency[n, default: 0] += 1 } }
        let chromeThreshold = max(3, Int((Double(framesWithText) * chromeShare).rounded(.up)))
        let chrome = framesWithText >= 4 ? Set(frequency.filter { $0.value >= chromeThreshold }.keys) : []

        // Emit only lines that are new relative to the last few kept frames, so a
        // slowly changing screen yields its changes rather than full repeats.
        var out: [(ms: Int, text: String)] = []
        var recent: [Set<String>] = []
        for (i, frame) in distinct.enumerated() {
            let seen = recent.reduce(into: Set<String>()) { $0.formUnion($1) }
            var emitted = Set<String>()
            let fresh = candidates[i].filter { line in
                guard !chrome.contains(line.norm), !seen.contains(line.norm) else { return false }
                return emitted.insert(line.norm).inserted
            }
            let current = Set(candidates[i].map(\.norm))
            if !current.isEmpty {
                recent.append(current)
                if recent.count > noveltyWindow { recent.removeFirst() }
            }
            guard !fresh.isEmpty else { continue }
            out.append((ms: frame.ms, text: fresh.map(\.raw).joined(separator: " · ")))
        }
        return out
    }

    /// Fraction of text-bearing frames a line must appear in to count as chrome.
    private static let chromeShare = 0.3
    /// Number of preceding text-bearing frames whose lines are not repeated.
    private static let noveltyWindow = 3

    /// Lock-protected result slots for the concurrent recognition pass.
    private final class LineSlots: @unchecked Sendable {
        private var slots: [[String]]
        private let lock = NSLock()
        init(count: Int) { slots = Array(repeating: [], count: count) }
        func set(_ i: Int, _ lines: [String]) { lock.withLock { slots[i] = lines } }
        func get(_ i: Int) -> [String] { lock.withLock { slots[i] } }
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
