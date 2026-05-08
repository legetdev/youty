import AppKit

// Frame model and timestamp computation used by the WKWebView canvas pipeline.
// AVFoundation-based extraction is archived in legacy_fast.md.

struct FrameExtractor {

    struct Frame {
        let timestamp: TimeInterval
        let image: NSImage
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
