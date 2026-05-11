import AppKit

// Frame model and timestamp computation.
//
// Density (per spec, 2025-05): cap 100 frames AND 2 fps.
//   count = min(countCap, max(1, floor(duration * fpsCap)))
//   interval = duration / count (evenly distributed across the full video)
// Future: countCap and fpsCap will be exposed as UI sliders.

struct FrameExtractor {

    struct Frame {
        let timestamp: TimeInterval
        let image: NSImage
    }

    static let defaultCountCap: Int = 100
    static let defaultFpsCap: Double = 2.0

    static func frameTimes(duration: TimeInterval,
                            countCap: Int = defaultCountCap,
                            fpsCap: Double = defaultFpsCap) -> [TimeInterval] {
        guard duration > 0 else { return [] }
        let raw = Int(floor(duration * fpsCap))
        let count = min(countCap, max(1, raw))
        let interval = duration / Double(count)
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
