import Foundation
import CoreML

/// On-device text `Embedder` backed by the Core ML EmbeddingGemma model + the
/// native `GemmaTokenizer`. Produces 768-d L2-normalized document embeddings
/// equivalent to the cloud Gemini path, with no API key and no third-party
/// dependency. See docs/s1-native-embedder.md.
///
/// The Core ML model runs EmbeddingGemma's full pipeline internally (mean pool,
/// Dense heads, normalize); Swift only tokenizes -> pads -> predicts.
final class EmbeddingGemmaEmbedder: Embedder, @unchecked Sendable {

    let modelIdentifier = "embeddinggemma-300m@768"
    let embeddingDim = 768

    /// Fixed sequence length the Core ML model was converted at.
    private static let seqLen = 256
    /// EmbeddingGemma's retrieval-document task prompt (the indexer embeds docs).
    private static let documentPrompt = "title: none | text: "

    private let model: MLModel
    private let tokenizer: GemmaTokenizer

    enum EmbedError: Error { case modelMissing, tokenizerMissing, noOutput }

    /// Explicit paths (used by tests/headless verification).
    init(modelURL: URL, tokenizerDirectory: URL) throws {
        self.tokenizer = try GemmaTokenizer(directory: tokenizerDirectory)
        let compiled = modelURL.pathExtension == "mlmodelc"
            ? modelURL
            : try MLModel.compileModel(at: modelURL)
        // CPU only. This model has int8-quantized weights; the GPU and Neural
        // Engine accumulate int8 matmuls in lower precision, which drags the
        // embedding cosine down to ~0.86–0.95. The CPU dequantizes weights to
        // float and matches the reference to 0.9998. Correctness over the ANE.
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .cpuOnly
        self.model = try MLModel(contentsOf: compiled, configuration: cfg)
    }

    /// Production: resolve the model + tokenizer from the app bundle, else the
    /// shared CLI/Homebrew location (same plumbing as SigLIPLoader).
    convenience init() throws {
        try self.init(modelURL: Self.resolveModel(),
                      tokenizerDirectory: Self.resolveTokenizerDir())
    }

    // MARK: Embedder

    func embed(_ texts: [String]) async throws -> [[Float]] {
        var out = [[Float]]()
        out.reserveCapacity(texts.count)
        for text in texts { out.append(try embedOne(text)) }
        return out
    }

    private func embedOne(_ text: String) throws -> [Float] {
        var ids = tokenizer.encode(Self.documentPrompt + text)
        // Truncate to seqLen keeping <bos> … <eos> (matches HF truncation).
        if ids.count > Self.seqLen {
            ids = [ids[0]] + Array(ids[1..<(Self.seqLen - 1)]) + [ids[ids.count - 1]]
        }
        let real = ids.count

        let inputIds = try MLMultiArray(shape: [1, NSNumber(value: Self.seqLen)], dataType: .int32)
        let mask = try MLMultiArray(shape: [1, NSNumber(value: Self.seqLen)], dataType: .int32)
        for i in 0..<Self.seqLen {
            inputIds[i] = NSNumber(value: i < real ? Int32(ids[i]) : Int32(GemmaTokenizer.pad))
            mask[i] = NSNumber(value: i < real ? Int32(1) : Int32(0))
        }

        let provider = try MLDictionaryFeatureProvider(
            dictionary: ["input_ids": inputIds, "attention_mask": mask])
        let result = try model.prediction(from: provider)
        guard let emb = result.featureValue(for: "embedding")?.multiArrayValue else {
            throw EmbedError.noOutput
        }
        var vec = [Float](repeating: 0, count: emb.count)
        for i in 0..<emb.count { vec[i] = emb[i].floatValue }
        return vec
    }

    // MARK: Resource resolution

    private static func resolveModel() throws -> URL {
        if let u = Bundle.main.url(forResource: "EmbeddingGemma-300m_text", withExtension: "mlmodelc") { return u }
        if let u = Bundle.main.url(forResource: "EmbeddingGemma-300m_text", withExtension: "mlpackage") { return u }
        if let u = SharedResourceLocator.url(named: "EmbeddingGemma-300m_text", extensions: ["mlmodelc", "mlpackage"]) { return u }
        throw EmbedError.modelMissing
    }

    private static func resolveTokenizerDir() throws -> URL {
        if let u = Bundle.main.url(forResource: "vocab", withExtension: "bin") { return u.deletingLastPathComponent() }
        if let u = SharedResourceLocator.url(named: "vocab", extensions: ["bin"]) { return u.deletingLastPathComponent() }
        throw EmbedError.tokenizerMissing
    }
}
