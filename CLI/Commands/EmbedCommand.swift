import Foundation

// `youty embed --text "..." [--query]`
//
// Emits the on-device EmbeddingGemma embedding of a string as compact JSON:
//   {"model":"embeddinggemma-300m@768","dim":768,"vector":[...]}
//
// It reuses the *exact* indexer pipeline (CPU-only Core ML + the native
// GemmaTokenizer), so a query embedded here lands in the same vector space as
// the stored documents — guaranteed parity. This is the foundation for the MCP
// shelling out for query embeddings instead of bundling torch + transformers.
enum EmbedCommand {

    static func run(_ args: ParsedArgs) -> Never {
        // --text "..." (or the first positional)
        let text = args.value(for: "text") ?? args.positionals.first
        guard let text, !text.isEmpty else {
            cliStderr("usage: youty embed --text \"...\" [--query]\n")
            exit(64)
        }
        let asQuery = args.bool("query")

        do {
            let embedder = try EmbeddingGemmaEmbedder()
            let vec = asQuery ? try embedder.embedQuery(text)
                              : try embedder.embedDocument(text)
            // Swift's Float description is the shortest round-trippable string,
            // so this transfers the vector without precision loss.
            let body = vec.map { String($0) }.joined(separator: ",")
            print("{\"model\":\"\(EmbeddingGemmaEmbedder.modelIdentifier)\",\"dim\":\(vec.count),\"vector\":[\(body)]}")
            exit(0)
        } catch {
            cliStderr("embed failed: \(error.localizedDescription)\n")
            exit(1)
        }
    }
}
