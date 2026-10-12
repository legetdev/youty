import Foundation
import CoreML
import CoreGraphics
import ImageIO

/// On-device EmbeddingGemma 2 (Google, Apache-2.0): one 768-d space shared by
/// transcript text, on-screen text, and video frames, so a single text query
/// can rank spoken and visual moments together. Fully on-device through
/// Core ML — no key, no network, no third-party runtime.
///
/// The Core ML packages take embeddings rather than token ids: Swift tokenizes,
/// looks each id up in the bf16 token table (× √512), and runs the smallest
/// fixed-length text function that fits. A frame runs through the vision
/// encoder first; its soft tokens are wrapped in `<bos> <|image> … <image|>
/// <eos>` and embedded by the same text model, which is what puts images and
/// text in one space.
final class EmbeddingGemma2: Embedder, @unchecked Sendable {

    /// Written to `chunks.model_version`, `frames.model_version`, and
    /// `index_meta` so the query side always matches the stored space.
    static let modelIdentifier = "embeddinggemma-2@768"
    var modelIdentifier: String { Self.modelIdentifier }
    let embeddingDim = 768

    /// Longest token sequence the converted text model accepts.
    static let maxTokens = 512
    /// EmbeddingGemma 2 retrieval prompts (from the model's sentence-transformers config).
    static let queryPrompt = "task: search result | query: "

    /// Document input in the model's native format. The video title fills the
    /// prompt's title slot so every chunk is anchored to its video.
    static func documentInput(title: String, text: String) -> String {
        let cleaned = title.replacingOccurrences(of: "|", with: "/")
            .components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return "title: \(cleaned.isEmpty ? "none" : cleaned) | text: \(text)"
    }

    private static let hidden = 512
    private static let embedScale = Float(512).squareRoot()
    private static let bos = 2, eos = 1, imageStart = 255_999, imageEnd = 258_882
    /// Vision soft-token budget per frame (the model's default). 280 tokens keep
    /// small on-screen text legible to the model; see `Scripts/verify-embeddinggemma2.py`.
    static let imageTokenBudget = 280
    private static let patch = 16, pooling = 3

    private let tokenizer: GemmaTokenizer
    private let tokenTable: Data      // bf16 [262144, 512], memory-mapped
    private let positionTable: Data   // f16 [2, 1024, 768], memory-mapped
    private let textURL: URL
    private let visionURL: URL
    private let lock = NSLock()
    private var textModels: [Int: MLModel] = [:]
    private var visionModel: MLModel?

    enum EmbedError: LocalizedError {
        case resourcesMissing, noOutput, unreadableImage(URL)
        var errorDescription: String? {
            switch self {
            case .resourcesMissing:
                return "The on-device search model isn't available. Reinstalling Youty restores it."
            case .noOutput:
                return "The on-device search model returned an unexpected result. Try restarting Youty."
            case .unreadableImage:
                return "Couldn't read a saved frame for search. The save still completed; visual search may be incomplete for this video."
            }
        }
    }

    // MARK: - Loading

    /// Process-wide instance: the token table is memory-mapped and each Core ML
    /// function loads once, so every save, re-index, and probe shares one copy.
    static func shared() throws -> EmbeddingGemma2 {
        try sharedLock.withLock {
            if let instance = sharedInstance { return instance }
            let made = try EmbeddingGemma2()
            sharedInstance = made
            return made
        }
    }
    nonisolated(unsafe) private static var sharedInstance: EmbeddingGemma2?
    private static let sharedLock = NSLock()

    convenience init() throws {
        guard let text = Self.resource("EmbeddingGemma2Text", ["mlmodelc", "mlpackage"]),
              let vision = Self.resource("EmbeddingGemma2Vision", ["mlmodelc", "mlpackage"]),
              let tokens = Self.resource("EmbeddingGemma2Tokens", ["bf16"]),
              let positions = Self.resource("EmbeddingGemma2Positions", ["f16"]),
              let vocab = Self.resource("vocab", ["bin"])
        else { throw EmbedError.resourcesMissing }
        try self.init(textURL: text, visionURL: vision, tokenTableURL: tokens,
                      positionTableURL: positions, tokenizerDirectory: vocab.deletingLastPathComponent())
    }

    init(textURL: URL, visionURL: URL, tokenTableURL: URL, positionTableURL: URL,
         tokenizerDirectory: URL) throws {
        tokenizer = try GemmaTokenizer(directory: tokenizerDirectory)
        tokenTable = try Data(contentsOf: tokenTableURL, options: .alwaysMapped)
        positionTable = try Data(contentsOf: positionTableURL, options: .alwaysMapped)
        guard tokenTable.count == 262_144 * Self.hidden * 2,
              positionTable.count == 2 * 1024 * 768 * 2 else { throw EmbedError.resourcesMissing }
        self.textURL = try Self.compiled(textURL)
        self.visionURL = try Self.compiled(visionURL)
    }

    private static func resource(_ name: String, _ exts: [String]) -> URL? {
        for ext in exts {
            if let url = Bundle.main.url(forResource: name, withExtension: ext) { return url }
        }
        return SharedResourceLocator.url(named: name, extensions: exts)
    }

    private static func compiled(_ url: URL) throws -> URL {
        url.pathExtension == "mlmodelc" ? url : try MLModel.compileModel(at: url)
    }

    /// Text runs on the Neural Engine (≈55 ms for a full 512-token chunk on an
    /// M1 Pro, ≈5× faster than the CPU). Core ML compiles each fixed-length
    /// function for the Neural Engine once per machine (≈2 minutes) and caches
    /// it, so Youty uses a single length for every document and frame; later
    /// launches load it in about a second. If the Neural Engine is unavailable
    /// the CPU computes the same embedding, only slower.
    private func textModel(_ length: Int) throws -> MLModel {
        try lock.withLock {
            if let model = textModels[length] { return model }
            let config = MLModelConfiguration()
            config.functionName = "embed_\(length)"
            config.computeUnits = .cpuAndNeuralEngine
            let model: MLModel
            do {
                model = try MLModel(contentsOf: textURL, configuration: config)
            } catch {
                config.computeUnits = .cpuOnly
                model = try MLModel(contentsOf: textURL, configuration: config)
            }
            textModels[length] = model
            return model
        }
    }

    /// Prepares the text model ahead of the first save, so its one-time
    /// Neural Engine compilation happens in the background. The vision model
    /// loads in seconds on first use and is left until a frame needs it.
    func warmUp() throws {
        _ = try textModel(Self.maxTokens)
    }

    /// The vision encoder runs on the GPU: its full attention over up to 2,520
    /// patches is faster there than on the Neural Engine, and it loads in seconds.
    private func visionModelLoaded() throws -> MLModel {
        try lock.withLock {
            if let visionModel { return visionModel }
            let config = MLModelConfiguration()
            config.computeUnits = .cpuAndGPU
            config.functionName = "vision_\(Self.imageTokenBudget)"
            let model = try MLModel(contentsOf: visionURL, configuration: config)
            visionModel = model
            return model
        }
    }

    // MARK: - Text

    /// Embeds already-formatted inputs verbatim (the chunker applies
    /// `documentInput`). Conforms to the indexer's `Embedder` contract.
    func embed(_ texts: [String]) async throws -> [[Float]] {
        try texts.map { try embedFormatted($0) }
    }

    func embedQuery(_ query: String) throws -> [Float] {
        try embedFormatted(Self.queryPrompt + query)
    }

    /// Exact model token count of `text`, excluding `<bos>` and `<eos>`.
    func contentTokens(_ text: String) -> Int { tokenizer.encode(text).count - 2 }

    func embedFormatted(_ text: String) throws -> [Float] {
        var ids = tokenizer.encode(text)
        if ids.count > Self.maxTokens { ids = Array(ids[..<(Self.maxTokens - 1)]) + [Self.eos] }
        return try runText(ids.map(Row.token))
    }

    private enum Row { case token(Int), soft(Int) }

    private func runText(_ rows: [Row], softTokens: MLMultiArray? = nil) throws -> [Float] {
        guard rows.count <= Self.maxTokens else { throw EmbedError.noOutput }
        let length = Self.maxTokens
        let embeds = try MLMultiArray(shape: [1, NSNumber(value: length), NSNumber(value: Self.hidden)], dataType: .float16)
        let mask = try MLMultiArray(shape: [1, NSNumber(value: length)], dataType: .float16)
        embeds.withUnsafeMutableBufferPointer(ofType: Float16.self) { dst, _ in
            dst.initialize(repeating: 0)
            tokenTable.withUnsafeBytes { raw in
                let table = raw.bindMemory(to: UInt16.self)
                for (position, row) in rows.enumerated() {
                    let out = position * Self.hidden
                    switch row {
                    case .token(let id):
                        let base = id * Self.hidden
                        for i in 0..<Self.hidden {
                            let value = Float(bitPattern: UInt32(table[base + i]) << 16) * Self.embedScale
                            dst[out + i] = Float16(value)
                        }
                    case .soft(let index):
                        softTokens?.withUnsafeBufferPointer(ofType: Float16.self) { src in
                            for i in 0..<Self.hidden { dst[out + i] = src[index * Self.hidden + i] }
                        }
                    }
                }
            }
        }
        mask.withUnsafeMutableBufferPointer(ofType: Float16.self) { dst, _ in
            for i in 0..<length { dst[i] = i < rows.count ? 1 : 0 }
        }
        let input = try MLDictionaryFeatureProvider(dictionary: ["inputs_embeds": embeds, "attention_mask": mask])
        let output = try textModel(length).prediction(from: input)
        guard let vector = output.featureValue(for: "embedding")?.multiArrayValue else { throw EmbedError.noOutput }
        return Self.normalized(Self.floats(vector))
    }

    // MARK: - Frames

    /// Embeds a saved frame into the shared space. The image is resized with its
    /// aspect ratio kept, to sides that are multiples of 48 px within the patch
    /// budget, exactly as Google's Gemma 4 image processor does.
    func embedImage(at url: URL) throws -> [Float] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw EmbedError.unreadableImage(url) }
        let budget = Self.imageTokenBudget
        let maxPatches = budget * Self.pooling * Self.pooling
        let (height, width) = Self.targetSize(height: image.height, width: image.width, maxPatches: maxPatches)
        guard let pixels = Self.rgbPixels(image, width: width, height: height) else { throw EmbedError.unreadableImage(url) }

        let rowsOfPatches = height / Self.patch, columns = width / Self.patch
        let count = rowsOfPatches * columns
        let tokens = count / (Self.pooling * Self.pooling)
        let patchValues = Self.patch * Self.patch * 3
        let n = NSNumber(value: maxPatches)

        let patches = try MLMultiArray(shape: [1, n, NSNumber(value: patchValues)], dataType: .float16)
        let positions = try MLMultiArray(shape: [1, n, 2], dataType: .float16)
        let positionEmbeddings = try MLMultiArray(shape: [1, n, 768], dataType: .float16)
        let valid = try MLMultiArray(shape: [1, n], dataType: .float16)
        let pool = try MLMultiArray(shape: [NSNumber(value: budget), n], dataType: .float16)

        patches.withUnsafeMutableBufferPointer(ofType: Float16.self) { dst, _ in
            dst.initialize(repeating: 0)
            for p in 0..<count {
                let py = p / columns, px = p % columns
                for r in 0..<Self.patch {
                    let rowStart = ((py * Self.patch + r) * width + px * Self.patch) * 4
                    for c in 0..<Self.patch {
                        let pixel = rowStart + c * 4
                        let out = p * patchValues + (r * Self.patch + c) * 3
                        for channel in 0..<3 { dst[out + channel] = Float16(Float(pixels[pixel + channel]) / 255) }
                    }
                }
            }
        }
        positions.withUnsafeMutableBufferPointer(ofType: Float16.self) { dst, _ in
            for p in 0..<maxPatches {
                dst[p * 2] = p < count ? Float16(p % columns) : -1
                dst[p * 2 + 1] = p < count ? Float16(p / columns) : -1
            }
        }
        positionEmbeddings.withUnsafeMutableBufferPointer(ofType: Float16.self) { dst, _ in
            dst.initialize(repeating: 0)
            positionTable.withUnsafeBytes { raw in
                let table = raw.bindMemory(to: Float16.self)
                for p in 0..<count {
                    let x = (p % columns) * 768, y = (1024 + p / columns) * 768
                    for i in 0..<768 { dst[p * 768 + i] = Float16(Float(table[x + i]) + Float(table[y + i])) }
                }
            }
        }
        valid.withUnsafeMutableBufferPointer(ofType: Float16.self) { dst, _ in
            for p in 0..<maxPatches { dst[p] = p < count ? 1 : 0 }
        }
        pool.withUnsafeMutableBufferPointer(ofType: Float16.self) { dst, _ in
            dst.initialize(repeating: 0)
            let pooledColumns = columns / Self.pooling
            for p in 0..<count {
                let token = (p % columns) / Self.pooling + pooledColumns * ((p / columns) / Self.pooling)
                dst[token * maxPatches + p] = Float16(1.0 / 9.0)
            }
        }

        let input = try MLDictionaryFeatureProvider(dictionary: [
            "patches": patches, "positions": positions, "position_embeddings": positionEmbeddings,
            "valid": valid, "pool": pool,
        ])
        let output = try visionModelLoaded().prediction(from: input)
        guard let soft = output.featureValue(for: "image_tokens")?.multiArrayValue,
              soft.dataType == .float16, soft.count >= tokens * Self.hidden else { throw EmbedError.noOutput }
        let rows: [Row] = [.token(Self.bos), .token(Self.imageStart)] + (0..<tokens).map(Row.soft)
            + [.token(Self.imageEnd), .token(Self.eos)]
        return try runText(rows, softTokens: soft)
    }

    /// Gemma 4 `get_aspect_ratio_preserving_size`: the largest size with both
    /// sides divisible by 48 px that stays within `maxPatches` 16-px patches.
    static func targetSize(height: Int, width: Int, maxPatches: Int) -> (height: Int, width: Int) {
        let side = patch * pooling
        let factor = (Double(maxPatches * patch * patch) / Double(height * width)).squareRoot()
        var h = Int((factor * Double(height) / Double(side)).rounded(.down)) * side
        var w = Int((factor * Double(width) / Double(side)).rounded(.down)) * side
        let maxSide = (maxPatches / (pooling * pooling)) * side
        if h == 0 { h = side; w = min(Int((Double(width) / Double(height)).rounded(.down)) * side, maxSide) }
        else if w == 0 { w = side; h = min(Int((Double(height) / Double(width)).rounded(.down)) * side, maxSide) }
        return (h, w)
    }

    /// RGBA8 pixels of `image` resampled to `width`×`height`, top row first.
    private static func rgbPixels(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }

    // MARK: - Helpers

    private static func floats(_ array: MLMultiArray) -> [Float] {
        switch array.dataType {
        case .float16:
            return array.withUnsafeBufferPointer(ofType: Float16.self) { $0.map(Float.init) }
        default:
            return array.withUnsafeBufferPointer(ofType: Float.self) { Array($0) }
        }
    }

    private static func normalized(_ v: [Float]) -> [Float] {
        let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return norm > 0 ? v.map { $0 / norm } : v
    }
}
