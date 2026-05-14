import Foundation
import CoreML
import CoreGraphics
import ImageIO
import AppKit

// MobileCLIP-S2 image embedder. Loads JPEGs from disk, resizes to 256x256
// RGB CVPixelBuffers, batches through the CoreML image encoder on the ANE,
// and returns L2-normalised 512-dim float vectors.

enum FrameEmbedderError: LocalizedError {
    case cannotDecode(URL)
    case cannotResize(URL)
    case predictionFailed(String)
    case unexpectedOutputShape(String)
    var errorDescription: String? {
        switch self {
        case .cannotDecode:
            return "Couldn't read a saved frame for image search. The save still completed; visual search may be incomplete for this video."
        case .cannotResize:
            return "Couldn't prepare a saved frame for image search. The save still completed; visual search may be incomplete for this video."
        case .predictionFailed, .unexpectedOutputShape:
            return "The image-search model returned an unexpected result. The save still completed; try restarting Youty if this keeps happening."
        }
    }
}

enum FrameEmbedder {

    /// Embeds a batch of JPEG URLs into 512-dim L2-normalised fp32 vectors.
    /// Runs the model one image at a time — CoreML/ANE batch dim is fixed
    /// at 1 in the published Apple model. Throughput on M-series ~3-5 ms/img.
    static func embedFrames(_ urls: [URL]) async throws -> [[Float]] {
        guard !urls.isEmpty else { return [] }
        let encoder = try await MobileCLIPLoader.shared.imageEncoder()
        let model = encoder.model
        var out: [[Float]] = []
        out.reserveCapacity(urls.count)
        for url in urls {
            guard let buffer = makePixelBuffer(at: url, size: mobileCLIPImageInputSize) else {
                throw FrameEmbedderError.cannotResize(url)
            }
            let input = try MLDictionaryFeatureProvider(dictionary: [
                "image": MLFeatureValue(pixelBuffer: buffer),
            ])
            let prediction: MLFeatureProvider
            do {
                prediction = try await model.prediction(from: input)
            } catch {
                throw FrameEmbedderError.predictionFailed(error.localizedDescription)
            }
            guard let arr = prediction.featureValue(for: "final_emb_1")?.multiArrayValue,
                  arr.count == mobileCLIPEmbeddingDim else {
                throw FrameEmbedderError.unexpectedOutputShape("expected [1,\(mobileCLIPEmbeddingDim)]")
            }
            out.append(l2Normalise(extractFloats(from: arr)))
        }
        return out
    }

    /// Loads a JPEG, center-crops to square, resizes to NxN, returns a
    /// 32ARGB CVPixelBuffer. ANE-compatible pixel format per Apple's
    /// reference iOS app for MobileCLIP.
    private static func makePixelBuffer(at url: URL, size: Int) -> CVPixelBuffer? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg  = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            return nil
        }

        // Center-square crop in source coordinates.
        let w = cg.width, h = cg.height
        let edge = min(w, h)
        let x = (w - edge) / 2, y = (h - edge) / 2
        guard let square = cg.cropping(to: CGRect(x: x, y: y, width: edge, height: edge)) else {
            return nil
        }

        // 32ARGB CVPixelBuffer at target size.
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:],
        ]
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(nil, size, size,
                                          kCVPixelFormatType_32ARGB,
                                          attrs as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buf = buffer else { return nil }

        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        let cs = CGColorSpaceCreateDeviceRGB()
        let bitmap = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                                  | CGBitmapInfo.byteOrder32Big.rawValue)
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buf),
                                   width: size, height: size,
                                   bitsPerComponent: 8,
                                   bytesPerRow: CVPixelBufferGetBytesPerRow(buf),
                                   space: cs,
                                   bitmapInfo: bitmap.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(square, in: CGRect(x: 0, y: 0, width: size, height: size))
        return buf
    }

    /// MLMultiArray fp16/fp32 → [Float] copy. Handles either dtype since the
    /// CoreML output is FLOAT16 on ANE but FLOAT32 if the model falls back.
    private static func extractFloats(from arr: MLMultiArray) -> [Float] {
        let n = arr.count
        var out = [Float](repeating: 0, count: n)
        switch arr.dataType {
        case .float32:
            arr.withUnsafeBufferPointer(ofType: Float.self) { ptr in
                for i in 0..<n { out[i] = ptr[i] }
            }
        case .float16:
            // Read raw 16-bit halves and promote via Float(Float16(...)).
            let bytes = arr.dataPointer
            let count = n
            for i in 0..<count {
                let raw = bytes.advanced(by: i * 2).load(as: UInt16.self)
                out[i] = Float(Float16(bitPattern: raw))
            }
        case .double:
            arr.withUnsafeBufferPointer(ofType: Double.self) { ptr in
                for i in 0..<n { out[i] = Float(ptr[i]) }
            }
        default:
            // Fallback: subscript indexing — slow but correct for unexpected dtypes.
            for i in 0..<n { out[i] = arr[i].floatValue }
        }
        return out
    }

    private static func l2Normalise(_ v: [Float]) -> [Float] {
        var sum: Float = 0
        for x in v { sum += x * x }
        let norm = sqrtf(sum)
        guard norm > 0 else { return v }
        return v.map { $0 / norm }
    }
}
