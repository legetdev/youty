import AVFoundation
import AppKit

// Local frame extraction from a downloaded H.264 MP4 file.
//
// Why ±2s tolerance:
//   At H.264 720p+, keyframes occur every 2–5s. With ±2s tolerance, every
//   requested timestamp resolves to a nearby keyframe — no decode-from-keyframe
//   needed → 100 frames in ~1–2s using hardware H.264 decode.
//
// Why generateCGImagesAsynchronously (the batch API):
//   Hands the entire request list to AVFoundation's own queue, which can
//   pipeline keyframe lookups and reuse decoder state across adjacent
//   timestamps. Measured ~2–3× faster than serial copyCGImage on Apple Silicon.

enum FastFrameExtractor {

    // Underdelivery threshold: if we get less than this fraction of requested
    // frames, the caller should fall back to canvas. Trips on corrupt MP4 or
    // unexpected codec mismatch.
    static let underdeliveryThreshold = 0.8

    // googlevideo signed URLs reject or stall requests with the default
    // CoreMedia User-Agent. They expect the ANDROID_VR UA we used to fetch
    // the URL in the first place.
    static func makeAsset(url: URL) -> AVURLAsset {
        return AVURLAsset(url: url, options: [
            "AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": StreamFetcher.androidVRUA]
        ])
    }

    static func extract(from videoURL: URL,
                        timestamps: [TimeInterval],
                        progress: @escaping @Sendable (Double) -> Void) async throws -> [FrameExtractor.Frame] {

        let asset = makeAsset(url: videoURL)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 720)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter  = CMTime(seconds: 2, preferredTimescale: 600)

        let times = timestamps.map { ts in
            NSValue(time: CMTimeMakeWithSeconds(ts, preferredTimescale: 600))
        }
        let totalCount = times.count

        return await withCheckedContinuation { (cont: CheckedContinuation<[FrameExtractor.Frame], Never>) in
            // Concurrent collection of results — generateCGImagesAsynchronously
            // calls the handler from its own queue.
            let collector = ResultCollector(total: totalCount)

            generator.generateCGImagesAsynchronously(forTimes: times) { requested, image, _, result, _ in
                Task {
                    if result == .succeeded, let image {
                        let ts = CMTimeGetSeconds(requested)
                        let frame = FrameExtractor.Frame(
                            timestamp: ts,
                            image: NSImage(cgImage: image, size: .zero)
                        )
                        let frac = await collector.append(frame)
                        progress(frac)
                    } else {
                        let frac = await collector.skip()
                        progress(frac)
                    }

                    if await collector.isComplete {
                        let frames = await collector.frames
                        cont.resume(returning: frames)
                    }
                }
            }
        }
    }
}

private actor ResultCollector {
    private(set) var frames: [FrameExtractor.Frame] = []
    private var done = 0
    private let total: Int

    init(total: Int) { self.total = total }

    func append(_ frame: FrameExtractor.Frame) -> Double {
        frames.append(frame)
        done += 1
        return Double(done) / Double(total)
    }

    func skip() -> Double {
        done += 1
        return Double(done) / Double(total)
    }

    var isComplete: Bool { done >= total }
}
