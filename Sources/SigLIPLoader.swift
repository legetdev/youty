import Foundation
import CoreML

// Lazy opener for Google's SigLIP-Base-Patch16-224 image encoder, shipped
// inside the app bundle as a Core ML .mlpackage. Replaces MobileCLIP-S2 —
// MobileCLIP's weights are governed by Apple's Machine Learning Research
// Model License, which restricts use to non-commercial research and
// excludes "use in any commercial product or service." SigLIP is
// Apache-2.0 (verified across HuggingFace API, model card frontmatter,
// and the google-research/big_vision LICENSE).
//
// File (bundled inside Youty.app/Contents/Resources/):
//   SigLIP-Base-224_image.mlpackage
//
// Source: google/siglip-base-patch16-224 (Apache-2.0). Conversion:
// Scripts/convert-siglip-coreml.py (one-off, traces with PyTorch,
// converts via coremltools, fp16 precision, bakes ImageType
// scale/bias for SigLIP's [-1, 1] normalization). Verified cosine vs
// PyTorch = 0.9999 at conversion time.
//
// Sandbox-safe: no network access at runtime, no third-party packages
// at runtime, model file is part of the signed app bundle so Gatekeeper
// covers it. Image encoder only — the text-query side runs in the
// Python MCP server via the HuggingFace transformers library, so the
// Swift app does not ship a tokenizer or text encoder.

enum SigLIPLoaderError: LocalizedError {
    case bundledModelMissing
    case modelCompile(String)
    case modelLoad(String)
    var errorDescription: String? {
        switch self {
        case .bundledModelMissing:
            return "Youty's image-search model is missing from the app bundle. Reinstall Youty from a fresh download to restore it."
        case .modelCompile:
            return "Couldn't prepare the image-search model. Try restarting Youty."
        case .modelLoad:
            return "Couldn't load the image-search model. Try restarting Youty."
        }
    }
}

/// Static identifier baked into `frames.model_version` so the indexer can
/// detect a model change across upgrades and trigger a partial reindex.
/// Format: `<model-card-name>@<output-dim>`. Bump when the model file
/// changes (different SigLIP variant, different quantization, etc.).
let siglipModelIdentifier = "siglip-base-patch16-224@768"
let siglipEmbeddingDim = 768
let siglipImageInputSize = 224

/// Thin `Sendable` wrapper around `MLModel`. CoreML guarantees that
/// `prediction(from:)` is safe to call from any thread on a single model
/// instance, but `MLModel` itself isn't declared `Sendable` — this struct
/// ferries the reference across actor boundaries cleanly.
struct SendableMLModel: @unchecked Sendable {
    let model: MLModel
    init(_ model: MLModel) { self.model = model }
}

actor SigLIPLoader {

    static let shared = SigLIPLoader()

    private var imageModel: MLModel?

    private init() {}

    /// Returns (and caches) the image encoder. First call loads from the
    /// bundled `.mlmodelc` (Xcode auto-compiles `.mlpackage` resources at
    /// build time), or falls back to runtime compilation of the source
    /// `.mlpackage` if for some reason the precompiled form isn't present.
    func imageEncoder() async throws -> SendableMLModel {
        if let imageModel { return SendableMLModel(imageModel) }
        let modelURL = try Self.bundledModelURL()
        let model = try loadModel(at: modelURL)
        self.imageModel = model
        return SendableMLModel(model)
    }

    /// Resolves the bundled image-encoder URL inside the app's Resources/.
    /// Prefers `.mlmodelc` (precompiled by Xcode at build time) and falls
    /// back to `.mlpackage` (source, requires runtime compile) if needed.
    /// Walks the bundle path manually as a third fallback for headless
    /// contexts where `Bundle.main` resolution can be flaky.
    static func bundledModelURL() throws -> URL {
        // Preferred: Xcode-precompiled .mlmodelc.
        if let url = Bundle.main.url(forResource: "SigLIP-Base-224_image",
                                      withExtension: "mlmodelc") {
            return url
        }
        // Source .mlpackage — Xcode may skip auto-compile in unusual configs.
        if let url = Bundle.main.url(forResource: "SigLIP-Base-224_image",
                                      withExtension: "mlpackage") {
            return url
        }
        // Manual Resources/ walk for headless / test contexts.
        let exe = Bundle.main.executableURL ?? Bundle.main.bundleURL
        let resourcesDir = exe
            .deletingLastPathComponent()           // MacOS/
            .deletingLastPathComponent()           // Contents/
            .appendingPathComponent("Resources")
        for ext in ["mlmodelc", "mlpackage"] {
            let candidate = resourcesDir
                .appendingPathComponent("SigLIP-Base-224_image.\(ext)")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        // CLI-tool fallback — when the CLI binary runs from a build
        // folder, the same Resources/ live in the sibling youty.app
        // bundle.
        let appResources = exe
            .deletingLastPathComponent()
            .appendingPathComponent("youty.app/Contents/Resources")
        for ext in ["mlmodelc", "mlpackage"] {
            let candidate = appResources
                .appendingPathComponent("SigLIP-Base-224_image.\(ext)")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        throw SigLIPLoaderError.bundledModelMissing
    }

    /// Opens an MLModel. If passed a `.mlmodelc` (Xcode-precompiled), loads
    /// directly. If passed a `.mlpackage` (source form), runs the runtime
    /// compile step first. Uses `.cpuAndNeuralEngine` so inference lands
    /// on ANE on Apple Silicon.
    private func loadModel(at url: URL) throws -> MLModel {
        let compiled: URL
        if url.pathExtension == "mlmodelc" {
            compiled = url
        } else {
            do {
                compiled = try MLModel.compileModel(at: url)
            } catch {
                throw SigLIPLoaderError.modelCompile(error.localizedDescription)
            }
        }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .cpuAndNeuralEngine
        do {
            return try MLModel(contentsOf: compiled, configuration: cfg)
        } catch {
            throw SigLIPLoaderError.modelLoad(error.localizedDescription)
        }
    }
}
