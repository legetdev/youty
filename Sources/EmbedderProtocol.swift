import Foundation

// Minimal surface every Phase B embedder implements. The indexer only ever
// embeds documents (header / description / body chunks); query embedding
// lives in the Python MCP server. New implementations (Voyage, CoreML BGE,
// Apple NLContextualEmbedding) plug in without touching Indexer.swift.

protocol Embedder: Sendable {
    /// Stable identifier written into `chunks.model_version` so the index
    /// can be partial-reindexed when models change.
    var modelIdentifier: String { get }

    /// Number of floats per returned embedding. Used to size the SQLite
    /// BLOB column and to validate provider responses.
    var embeddingDim: Int { get }

    /// Returns one embedding per input text, in the same order.
    func embed(_ texts: [String]) async throws -> [[Float]]
}
