import Foundation

// Minimal surface the indexer needs from a document embedder. Production uses
// `EmbeddingGemma2`; probes and tests can substitute their own. Query
// embedding for agents lives in the Python MCP server.

protocol Embedder: Sendable {
    /// Stable identifier written into `chunks.model_version` so the index
    /// can be partial-reindexed when models change.
    var modelIdentifier: String { get }

    /// Number of floats per returned embedding. Used to size the SQLite
    /// BLOB column and to validate provider responses.
    var embeddingDim: Int { get }

    /// Returns one embedding per input text, in the same order.
    func embed(_ texts: [String]) async throws -> [[Float]]

    /// Model tokens in `text` (excluding `<bos>`/`<eos>`), used to size chunks
    /// so none overflows the model window.
    func contentTokens(_ text: String) -> Int
}

extension Embedder {
    func contentTokens(_ text: String) -> Int { Chunker.approxTokens(text) }
}
