import AVFoundation
import AppKit

struct FrameExtractor {

    struct Frame {
        let timestamp: TimeInterval
        let image: NSImage
    }

    // Resolution used for frame extraction. 720p is the default.
    // AVAssetImageGenerator scales proportionally — portrait/vertical video is handled automatically.
    static let frameSize = CGSize(width: 1280, height: 720)

    static func extract(from videoURL: URL) async throws -> [Frame] {
        let asset = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        let times = frameTimes(duration: seconds)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = frameSize
        // Generous tolerance so AVFoundation can seek to the nearest keyframe quickly
        // rather than decoding every intermediate frame. Critical for speed on remote URLs.
        generator.requestedTimeToleranceBefore = CMTimeMakeWithSeconds(2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter  = CMTimeMakeWithSeconds(2, preferredTimescale: 600)

        let nsValues = times.map { NSValue(time: CMTimeMakeWithSeconds($0, preferredTimescale: 600)) }

        return try await withCheckedThrowingContinuation { continuation in
            var results: [(TimeInterval, NSImage)] = []
            let total = nsValues.count
            guard total > 0 else { continuation.resume(returning: []); return }
            var count = 0

            generator.generateCGImagesAsynchronously(forTimes: nsValues) { requestedTime, cgImage, _, result, _ in
                if result == .succeeded, let cgImage {
                    results.append((CMTimeGetSeconds(requestedTime), NSImage(cgImage: cgImage, size: .zero)))
                }
                count += 1
                if count == total {
                    let frames = results.sorted { $0.0 < $1.0 }.map { Frame(timestamp: $0.0, image: $0.1) }
                    continuation.resume(returning: frames)
                }
            }
        }
    }

    // ≤100s: 1 frame per second (up to 100 frames)
    // >100s: exactly 100 frames evenly distributed
    static func frameTimes(duration: TimeInterval) -> [TimeInterval] {
        let count = duration <= 100 ? max(1, Int(duration)) : 100
        let interval = duration <= 100 ? 1.0 : duration / 100.0
        return (0..<count).map { Double($0) * interval }
    }
}

extension NSImage {
    func jpegData(compressionQuality: CGFloat) -> Data? {
        guard let tiff = tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .jpeg,
                                     properties: [.compressionFactor: compressionQuality])
    }
}
