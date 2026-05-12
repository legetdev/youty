import Foundation
import AppKit
import AVFoundation
import CoreImage

// Frame extraction from a local progressive MP4 file via
// AVAssetImageGenerator. Used by the Instagram + TikTok flows where the
// video has already been downloaded to a temp file by MediaDownloader.
//
// Why not the FFmpeg pipeline:
//   Instagram + TikTok serve progressive MP4 (single moov + mdat), not
//   DASH-fragmented. AVAssetImageGenerator handles this container perfectly —
//   it's the API designed for "give me frames at these PTSes from a local
//   file". On Apple Silicon this is hardware-accelerated H.264 decode with
//   zero copy through VideoToolbox.
//
// The historical reason we built the FFmpeg pipeline (AVFoundation hangs /
// fails on YouTube's DASH-fragmented stream past the midpoint) does not
// apply here: short-form progressive MP4 is exactly AVFoundation's sweet
// spot.

enum LocalFrameExtractorError: LocalizedError {
    case noVideoTrack
    case noFrameAtTimestamp(TimeInterval)
    case imageConversionFailed(at: TimeInterval)
    case underlying(Error)
    var errorDescription: String? {
        switch self {
        case .noVideoTrack:              return "Downloaded media has no video track."
        case .noFrameAtTimestamp(let t): return "No frame near \(String(format: "%.2f", t)) s."
        case .imageConversionFailed(let t): return "Could not convert frame at \(String(format: "%.2f", t)) s."
        case .underlying(let e):         return e.localizedDescription
        }
    }
}

enum LocalFrameExtractor {

    /// Extracts frames at each timestamp from a local file. Returns frames
    /// in input order. Each frame is rendered at the source's native
    /// resolution, then optionally downscaled to fit `maxLongEdge`.
    ///
    /// - Parameters:
    ///   - fileURL: a sandbox-readable local file.
    ///   - timestamps: requested PTSes in seconds.
    ///   - maxLongEdge: max long-edge in pixels; pass 0 for no cap.
    static func extract(
        fileURL: URL,
        timestamps: [TimeInterval],
        maxLongEdge: Int = 1920,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> [(timestamp: TimeInterval, image: NSImage)] {

        let asset = AVURLAsset(url: fileURL)
        // Confirm there's a video track so we error fast on audio-only inputs.
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = tracks.first else { throw LocalFrameExtractorError.noVideoTrack }

        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let displaySize = naturalSize.applying(preferredTransform)
        let dispW = abs(displaySize.width)
        let dispH = abs(displaySize.height)
        let dispMax = max(dispW, dispH)
        let scale: CGFloat = (maxLongEdge > 0 && dispMax > CGFloat(maxLongEdge))
            ? CGFloat(maxLongEdge) / dispMax
            : 1.0
        let outW = Int((dispW * scale).rounded())
        let outH = Int((dispH * scale).rounded())

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: outW, height: outH)
        generator.requestedTimeToleranceBefore = .init(seconds: 0.05, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter  = .init(seconds: 0.05, preferredTimescale: 600)

        let cmTimes = timestamps.map { CMTime(seconds: $0, preferredTimescale: 600) }

        let progressBox = LocalExtractorProgressBox(total: timestamps.count, callback: progress)
        let results = LocalExtractorResultsBox(slotCount: timestamps.count)
        let genBox = SendableImageGenerator(generator)

        try await withThrowingTaskGroup(of: Void.self) { group in
            // 4-way concurrency. AVAssetImageGenerator's async API serialises
            // requests internally, but spawning small chunks keeps the
            // backpressure tight and lets us bail fast on errors.
            let chunks = stride(from: 0, to: timestamps.count, by: 25).map { start -> Range<Int> in
                start..<min(start + 25, timestamps.count)
            }
            for chunk in chunks {
                let times = chunk.map { (idx: $0, cm: cmTimes[$0]) }
                group.addTask {
                    for entry in times {
                        let (image, _) = try await genBox.value.image(at: entry.cm)
                        let ns = NSImage(cgImage: image,
                                          size: NSSize(width: image.width, height: image.height))
                        results.set(slot: entry.idx, image: ns)
                        progressBox.tick()
                    }
                }
            }
            try await group.waitForAll()
        }

        let captured = results.takeAll()
        var out: [(TimeInterval, NSImage)] = []
        out.reserveCapacity(timestamps.count)
        for (i, ts) in timestamps.enumerated() {
            guard let img = captured[i] else {
                throw LocalFrameExtractorError.noFrameAtTimestamp(ts)
            }
            out.append((ts, img))
        }
        return out
    }
}

private final class LocalExtractorResultsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var images: [NSImage?]
    init(slotCount: Int) { images = Array(repeating: nil, count: slotCount) }
    func set(slot: Int, image: NSImage) {
        lock.lock(); images[slot] = image; lock.unlock()
    }
    func takeAll() -> [NSImage?] {
        lock.lock(); defer { lock.unlock() }
        return images
    }
}

private final class SendableImageGenerator: @unchecked Sendable {
    let value: AVAssetImageGenerator
    init(_ v: AVAssetImageGenerator) { value = v }
}

private final class LocalExtractorProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var done = 0
    private let total: Int
    private let callback: @Sendable (Double) -> Void
    init(total: Int, callback: @escaping @Sendable (Double) -> Void) {
        self.total = total
        self.callback = callback
    }
    func tick() {
        lock.lock(); done += 1; let d = done; lock.unlock()
        callback(Double(d) / Double(max(total, 1)))
    }
}
