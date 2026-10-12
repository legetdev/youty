import Foundation

// `youty embed --text "..." [--query]`
//
// Emits the on-device EmbeddingGemma 2 embedding of a string as compact JSON:
//   {"model":"embeddinggemma-2@768","dim":768,"vector":[...]}
//
// It reuses the indexer's exact pipeline (Core ML + the native GemmaTokenizer),
// so a vector produced here lands in the same space as the stored documents
// and frames. Without `--query` the text is embedded as an untitled document.
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
            let embedder = try EmbeddingGemma2.shared()
            let vec = asQuery ? try embedder.embedQuery(text)
                              : try embedder.embedFormatted(EmbeddingGemma2.documentInput(title: "", text: text))
            // Swift's Float description is the shortest round-trippable string,
            // so this transfers the vector without precision loss.
            let body = vec.map { String($0) }.joined(separator: ",")
            print("{\"model\":\"\(EmbeddingGemma2.modelIdentifier)\",\"dim\":\(vec.count),\"vector\":[\(body)]}")
            exit(0)
        } catch {
            cliStderr("embed failed: \(error.localizedDescription)\n")
            exit(1)
        }
    }
}
