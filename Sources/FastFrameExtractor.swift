import AVFoundation
import AppKit

// Local frame extraction from a downloaded MP4 file.
//
// We rely on the StreamFetcher preferring PROGRESSIVE H.264 formats over
// DASH-fragmented ones. Progressive MP4s have moov at the file start and a
// single H.264 SPS/PPS that covers the entire stream — AVAssetImageGenerator
// reads them cleanly end-to-end.
//
// We empirically verified that AVAssetImageGenerator, AVAssetReader, and
// AVAssetExportSession ALL silently fail past the midpoint on YouTube's
// DASH-fragmented H.264 streams. Those streams switch H.264 SPS/PPS at the
// midpoint and AVFoundation's decoder doesn't pick up the in-band update.
// We therefore avoid adaptive streams whenever a progressive option exists.

enum ExtractionError: LocalizedError {
    case incompleteFrames(got: Int, expected: Int)
    case durationLoadFailed

    var errorDescription: String? {
        switch self {
        case .incompleteFrames(let got, let expected):
            return "Saved \(got) of \(expected) frames. Try the alternative extractor for full coverage."
        case .durationLoadFailed:
            return "Couldn't read the video's duration. Try a different video."
        }
    }
}

enum FastFrameExtractor {

    static func loadDuration(from localURL: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(url: localURL)
        let cm = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(cm)
        guard seconds > 0, seconds.isFinite else { throw ExtractionError.durationLoadFailed }
        return seconds
    }

    static func extract(from localURL: URL,
                        timestamps: [TimeInterval],
                        progress: @escaping @Sendable (Double) -> Void) async throws -> [FrameExtractor.Frame] {

        let asset = AVURLAsset(url: localURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 720)
        // ±0.5s tolerance: tight enough to land near the requested moment,
        // loose enough that hardware H.264 decode doesn't need to walk far
        // from a keyframe.
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter  = CMTime(seconds: 0.5, preferredTimescale: 600)

        var captured: [FrameExtractor.Frame] = []
        captured.reserveCapacity(timestamps.count)

        // Serial calls via the macOS-13+ async API. Apple Silicon hardware
        // decode is fast enough that 100 frames take ~1–3s.
        for (i, ts) in timestamps.enumerated() {
            let cm = CMTimeMakeWithSeconds(ts, preferredTimescale: 600)
            let result = try await generator.image(at: cm)
            let frame = FrameExtractor.Frame(
                timestamp: ts,
                image: NSImage(cgImage: result.image, size: .zero)
            )
            captured.append(frame)
            progress(Double(i + 1) / Double(timestamps.count))
        }

        if captured.count == timestamps.count {
            return captured
        }
        throw ExtractionError.incompleteFrames(got: captured.count, expected: timestamps.count)
    }
}
