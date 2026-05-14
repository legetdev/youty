import Foundation
import CoreML

// Lazy downloader + opener for Apple's MobileCLIP-S2 CoreML encoders.
//
// The Mac app and the Python MCP server share one model directory at
// ~/Library/Application Support/Youty/models/ so a single ~200 MB download
// is enough to cover both indexing (Swift) and query embedding (Python).
//
// Files (downloaded lazily on first use, idempotent thereafter):
//   models/mobileclip_s2_image.mlpackage/
//   models/mobileclip_s2_text.mlpackage/
//   models/clip_vocab.json
//   models/clip_merges.txt
//
// Source: https://huggingface.co/apple/coreml-mobileclip — the official
// Apple-published CoreML conversion of the MobileCLIP family. Tokenizer
// vocab/merges are the standard OpenAI CLIP BPE published under
// openai/clip-vit-base-patch32. Both downloaded over HTTPS via URLSession —
// no third-party packages, App Store-safe.

enum MobileCLIPLoaderError: LocalizedError {
    case download(URL, Int)
    case fileMove(URL, URL, String)
    case modelLoad(URL, String)
    var errorDescription: String? {
        switch self {
        case .download:
            return "Couldn't download the image-search model. Check your internet connection and try saving again — the model only downloads once."
        case .fileMove:
            return "Couldn't install the image-search model on disk. Make sure Youty has enough free space, then try again."
        case .modelLoad:
            return "Couldn't load the image-search model. Try restarting Youty."
        }
    }
}

/// Static identifier baked into `frames.model_version` for partial reindex.
let mobileCLIPModelIdentifier = "mobileclip-s2@512"
let mobileCLIPEmbeddingDim = 512
let mobileCLIPImageInputSize = 256

/// Thin `Sendable` wrapper around `MLModel`. CoreML guarantees that
/// `prediction(from:)` is safe to call from any thread on a single model
/// instance, but `MLModel` itself isn't declared `Sendable` — this struct
/// ferries the reference across actor boundaries cleanly.
struct SendableMLModel: @unchecked Sendable {
    let model: MLModel
    init(_ model: MLModel) { self.model = model }
}

actor MobileCLIPLoader {

    static let shared = MobileCLIPLoader()

    private var imageModel: MLModel?
    private var textModel: MLModel?

    private init() {}

    /// Returns (and caches) the image encoder. First call may download ~71 MB.
    /// The returned MLModel is shipped across actor boundaries via an unsafe
    /// wrapper — CoreML's MLModel is thread-safe for `.prediction(from:)` per
    /// Apple's docs even though it's not formally `Sendable`.
    func imageEncoder() async throws -> SendableMLModel {
        if let imageModel { return SendableMLModel(imageModel) }
        let pkgURL = try await ensurePackage(name: "mobileclip_s2_image.mlpackage",
                                              fileSize: 71_397_632)
        let model = try loadModel(at: pkgURL)
        self.imageModel = model
        return SendableMLModel(model)
    }

    /// Returns (and caches) the text encoder. First call may download ~127 MB.
    func textEncoder() async throws -> SendableMLModel {
        if let textModel { return SendableMLModel(textModel) }
        let pkgURL = try await ensurePackage(name: "mobileclip_s2_text.mlpackage",
                                              fileSize: 126_866_880)
        let model = try loadModel(at: pkgURL)
        self.textModel = model
        return SendableMLModel(model)
    }

    /// Absolute model directory shared with the Python MCP server.
    static func modelsDirectory() throws -> URL {
        let appSupport = try FileManager.default.url(for: .applicationSupportDirectory,
                                                      in: .userDomainMask,
                                                      appropriateFor: nil,
                                                      create: true)
        let dir = appSupport
            .appendingPathComponent("Youty", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Package download

    /// Downloads (only if missing) the two files comprising one .mlpackage
    /// from apple/coreml-mobileclip on HuggingFace. Idempotent.
    private func ensurePackage(name: String, fileSize: Int) async throws -> URL {
        let base = try Self.modelsDirectory()
        let pkgURL = base.appendingPathComponent(name, isDirectory: true)
        let modelMLModel = pkgURL
            .appendingPathComponent("Data/com.apple.CoreML/model.mlmodel")
        let weights = pkgURL
            .appendingPathComponent("Data/com.apple.CoreML/weights/weight.bin")
        let manifest = pkgURL.appendingPathComponent("Manifest.json")

        let fm = FileManager.default
        let weightsExist = fm.fileExists(atPath: weights.path)
        let weightsSize = ((try? fm.attributesOfItem(atPath: weights.path))?[.size] as? Int) ?? 0
        let modelExists = fm.fileExists(atPath: modelMLModel.path)
        if weightsExist && modelExists && weightsSize == fileSize {
            return pkgURL
        }

        try fm.createDirectory(at: weights.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        // Mlpackage files on HuggingFace are addressable individually via the
        // `resolve/main/<path>` convention. Pull the three we need.
        let baseHF = "https://huggingface.co/apple/coreml-mobileclip/resolve/main/\(name)"
        try await downloadIfMissing(URL(string: "\(baseHF)/Manifest.json")!, to: manifest)
        try await downloadIfMissing(URL(string: "\(baseHF)/Data/com.apple.CoreML/model.mlmodel")!,
                                     to: modelMLModel)
        try await downloadIfMissing(URL(string: "\(baseHF)/Data/com.apple.CoreML/weights/weight.bin")!,
                                     to: weights,
                                     expectedSize: fileSize)
        return pkgURL
    }

    /// HEAD-respecting downloader. Writes to `<dest>.part` then renames.
    /// Validates size when `expectedSize` is supplied.
    private func downloadIfMissing(_ url: URL, to dest: URL, expectedSize: Int? = nil) async throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) {
            if let expected = expectedSize {
                let size = ((try? fm.attributesOfItem(atPath: dest.path))?[.size] as? Int) ?? 0
                if size == expected { return }
                try? fm.removeItem(at: dest)
            } else {
                return
            }
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        // HF returns 302 → CDN; URLSession follows by default.
        let (tmpFile, response) = try await URLSession.shared.download(for: req)
        defer { try? fm.removeItem(at: tmpFile) }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw MobileCLIPLoaderError.download(url, code)
        }
        let partURL = dest.appendingPathExtension("part")
        try? fm.removeItem(at: partURL)
        do {
            try fm.moveItem(at: tmpFile, to: partURL)
            try fm.moveItem(at: partURL, to: dest)
        } catch {
            throw MobileCLIPLoaderError.fileMove(tmpFile, dest, error.localizedDescription)
        }
        if let expected = expectedSize {
            let size = ((try? fm.attributesOfItem(atPath: dest.path))?[.size] as? Int) ?? 0
            if size != expected {
                try? fm.removeItem(at: dest)
                throw MobileCLIPLoaderError.download(url, -2)
            }
        }
    }

    /// Compiles + opens an MLModel from a .mlpackage on disk. Uses
    /// `.cpuAndNeuralEngine` so inference lands on ANE on Apple Silicon.
    private func loadModel(at url: URL) throws -> MLModel {
        do {
            let compiled = try MLModel.compileModel(at: url)
            let cfg = MLModelConfiguration()
            cfg.computeUnits = .cpuAndNeuralEngine
            return try MLModel(contentsOf: compiled, configuration: cfg)
        } catch {
            throw MobileCLIPLoaderError.modelLoad(url, error.localizedDescription)
        }
    }
}

/// Returns the URLs of the CLIP tokenizer vocab + merges files, downloading
/// once into the same models dir. Used by any tokenizer impl that needs them.
func ensureCLIPTokenizerFiles() async throws -> (vocab: URL, merges: URL) {
    let dir = try MobileCLIPLoader.modelsDirectory()
    let vocab = dir.appendingPathComponent("clip_vocab.json")
    let merges = dir.appendingPathComponent("clip_merges.txt")
    let fm = FileManager.default
    if !fm.fileExists(atPath: vocab.path) {
        let url = URL(string: "https://huggingface.co/openai/clip-vit-base-patch32/resolve/main/vocab.json")!
        let (tmp, resp) = try await URLSession.shared.download(from: url)
        defer { try? fm.removeItem(at: tmp) }
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw MobileCLIPLoaderError.download(url, (resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        try fm.moveItem(at: tmp, to: vocab)
    }
    if !fm.fileExists(atPath: merges.path) {
        let url = URL(string: "https://huggingface.co/openai/clip-vit-base-patch32/resolve/main/merges.txt")!
        let (tmp, resp) = try await URLSession.shared.download(from: url)
        defer { try? fm.removeItem(at: tmp) }
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw MobileCLIPLoaderError.download(url, (resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        try fm.moveItem(at: tmp, to: merges)
    }
    return (vocab, merges)
}
