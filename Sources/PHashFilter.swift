import Foundation
import Vision
import CoreGraphics
import ImageIO

// Near-duplicate frame filter. Uses Apple's `VNGenerateImageFeaturePrintRequest`
// (sandbox-safe, ANE-accelerated) to compute a 1×N feature print per JPEG
// and drops frames whose distance to the most recently kept frame falls
// below `distanceThreshold`. Aim: ~3-6× reduction on slide-heavy content.

enum PHashFilter {

    /// Returns indices of the JPEGs to keep. Always keeps index 0.
    /// `distanceThreshold` is Apple's `computeDistance` output — empirically
    /// 0.3 is the sweet spot per Apple's WWDC docs ("noticeably different").
    static func keepIndices(jpegURLs: [URL],
                             distanceThreshold: Float = 0.3) -> [Int] {
        guard !jpegURLs.isEmpty else { return [] }

        var keep: [Int] = [0]
        var lastPrint: VNFeaturePrintObservation? = featurePrint(at: jpegURLs[0])
        // If we can't read the first frame, still keep its index so the caller
        // sees a 1:1 mapping; embedder will fail downstream if truly unreadable.

        for i in 1..<jpegURLs.count {
            guard let candidate = featurePrint(at: jpegURLs[i]) else {
                // Conservatively keep frames we can't fingerprint — better to
                // embed a few extra than to silently drop content.
                keep.append(i)
                lastPrint = nil
                continue
            }
            if let prev = lastPrint {
                var dist: Float = 0
                do {
                    try prev.computeDistance(&dist, to: candidate)
                } catch {
                    keep.append(i)
                    lastPrint = candidate
                    continue
                }
                if dist >= distanceThreshold {
                    keep.append(i)
                    lastPrint = candidate
                }
                // else: too similar — drop, lastPrint stays the same.
            } else {
                keep.append(i)
                lastPrint = candidate
            }
        }
        return keep
    }

    /// Returns a coarse 64-bit perceptual hash by quantising the first 64
    /// dims of the feature print. Stored alongside each kept frame so a
    /// future "find visually similar" path can do cheap Hamming distance.
    static func phash(at url: URL) -> UInt64? {
        guard let print = featurePrint(at: url) else { return nil }
        let data = print.data
        // Float32, 1×N — sign-bit pack the first 64 elements into a UInt64.
        let count = data.count / MemoryLayout<Float>.size
        let n = min(count, 64)
        guard n > 0 else { return nil }
        var hash: UInt64 = 0
        data.withUnsafeBytes { raw in
            let ptr = raw.bindMemory(to: Float.self)
            for i in 0..<n {
                if ptr[i] > 0 { hash |= (1 << UInt64(i)) }
            }
        }
        return hash
    }

    // MARK: - Internal

    private static func featurePrint(at url: URL) -> VNFeaturePrintObservation? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        let req = VNGenerateImageFeaturePrintRequest()
        do {
            try handler.perform([req])
        } catch {
            return nil
        }
        return req.results?.first
    }
}
