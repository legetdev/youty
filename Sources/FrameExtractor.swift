import AppKit

// Frame model and timestamp computation.
//
// Density (per spec, 2025-05): cap 100 frames AND 2 fps.
//   count = min(countCap, max(1, floor(duration * fpsCap)))
//   interval = duration / count (evenly distributed across the full video)
// Future: countCap and fpsCap will be exposed as UI sliders.

struct FrameExtractor {

    /// A captured frame, held as the JPEG the vault stores. It's encoded once,
    /// the moment the frame is captured, so a capture keeps a few hundred KB
    /// per frame instead of a multi-megabyte bitmap (100 frames ≈ 20 MB, not
    /// ≈ 800 MB), and nothing is compressed twice.
    struct Frame {
        static let jpegQuality: CGFloat = 0.85
        let timestamp: TimeInterval
        let jpeg: Data

        init(timestamp: TimeInterval, image: NSImage) {
            self.timestamp = timestamp
            if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                self.jpeg = Self.encode(cg)
            } else {
                self.jpeg = autoreleasepool { image.jpegData(compressionQuality: Self.jpegQuality) ?? Data() }
            }
        }

        init(timestamp: TimeInterval, cgImage: CGImage) {
            self.timestamp = timestamp
            self.jpeg = Self.encode(cgImage)
        }

        /// Encodes straight from the bitmap (no TIFF round trip) and frees the
        /// encoder's temporaries now — capture loops run as one long task, so
        /// autoreleased buffers would otherwise pile up frame after frame.
        private static func encode(_ image: CGImage) -> Data {
            autoreleasepool {
                NSBitmapImageRep(cgImage: image)
                    .representation(using: .jpeg, properties: [.compressionFactor: jpegQuality]) ?? Data()
            }
        }

        var image: NSImage? { NSImage(data: jpeg) }
    }

    static let defaultCountCap: Int = 100
    static let defaultFpsCap: Double = 2.0

    static func frameTimes(duration: TimeInterval,
                            countCap: Int = defaultCountCap,
                            fpsCap: Double = defaultFpsCap) -> [TimeInterval] {
        guard duration.isFinite, duration > 0, fpsCap.isFinite, fpsCap > 0, countCap > 0 else { return [] }
        // Clamp before converting to Int so corrupt metadata cannot overflow.
        let requested = max(1, floor(duration * fpsCap))
        let count = requested >= Double(countCap) ? countCap : Int(requested)
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
