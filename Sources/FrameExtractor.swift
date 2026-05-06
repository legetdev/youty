import AVFoundation
import AppKit

struct FrameExtractor {

    struct Frame {
        let timestamp: TimeInterval
        let image: NSImage
    }

    static func extract(from videoURL: URL) async throws -> [Frame] {
        let asset = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        let times = frameTimes(duration: seconds)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 720)
        generator.requestedTimeToleranceBefore = CMTimeMakeWithSeconds(1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter  = CMTimeMakeWithSeconds(1, preferredTimescale: 600)

        let nsValues = times.map { NSValue(time: CMTimeMakeWithSeconds($0, preferredTimescale: 600)) }

        return try await withCheckedThrowingContinuation { continuation in
            var results: [(TimeInterval, NSImage)] = []
            let total = nsValues.count
            guard total > 0 else { continuation.resume(returning: []); return }
            var count = 0

            // generateCGImagesAsynchronously calls the handler once per time value, in order.
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

    // Density scales with video length, capped at 100 frames.
    static func frameTimes(duration: TimeInterval) -> [TimeInterval] {
        let interval: TimeInterval
        switch duration {
        case ..<300:     interval = 10   // every 10s for <5 min
        case 300..<1800: interval = 30   // every 30s for 5–30 min
        default:         interval = duration / 100
        }
        var times: [TimeInterval] = []
        var t: TimeInterval = 0
        while t < duration { times.append(t); t += interval }
        return times
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
