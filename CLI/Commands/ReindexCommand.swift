import Foundation

// `youty reindex` — rebuilds the local search index for the resolved vault.
//
// Default: full (text + frames). `--text-only` re-embeds just transcript text
// (the fast Phase S.4 migration path; frames keep their SigLIP vectors). Honours
// --embedder / the saved cli-config provider exactly like `save`, so a CLI-only
// user can migrate an old Gemini index to on-device embeddings with no key.
//
// Pure compute (DB + Core ML, no WKWebView), so it runs on a detached Task and
// blocks main on a semaphore — no NSApplication run loop required.

enum ReindexCommand {

    static func run(_ args: ParsedArgs) -> Never {
        guard let vaultResolution = VaultResolver.resolve(flagValue: args.value(for: "vault"),
                                                          persist: true) else {
            cliStderr(VaultResolver.noVaultMessage + "\n")
            exit(78)
        }
        if let raw = args.value(for: "embedder"),
           EmbeddingProvider(rawValue: raw.lowercased()) == nil {
            cliStderr("error: --embedder must be 'local' (on-device) or 'gemini' (cloud).\n")
            exit(64)
        }
        let textOnly = args.bool("text-only")
        let quiet = args.bool("quiet") || args.bool("q")
        let provider = resolveProvider(args)
        let vaultURL = vaultResolution.url

        if !quiet {
            cliStderr("• Vault: \(vaultURL.path) (from \(vaultResolution.source.label))\n")
            cliStderr("• Re-embedding \(textOnly ? "text only" : "text + frames") with \(provider == .local ? "on-device" : "Gemini")…\n")
        }

        let sem = DispatchSemaphore(value: 0)
        let box = ReindexBox()
        Task.detached {
            defer { sem.signal() }
            do {
                let embedder = try Indexer.makeEmbedder(for: provider)
                let progress: ((String) -> Void)? = quiet ? nil : { line in
                    FileHandle.standardError.write("  \(line)\n".data(using: .utf8)!)
                }
                let summary: ReindexSummary = textOnly
                    ? try await Indexer.reindexTextEmbeddings(vaultRoot: vaultURL,
                                                              embedderOverride: embedder,
                                                              progress: progress)
                    : try await Indexer.reindexVault(vaultRoot: vaultURL,
                                                     embedderOverride: embedder,
                                                     progress: progress)
                let scope = textOnly ? "text" : "text + frames"
                Swift.print("Re-embedded \(summary.videosIndexed) video(s), \(summary.chunksWritten) chunks (\(scope)) in \(summary.totalMs)ms"
                    + (summary.framesKept > 0 ? " · \(summary.framesKept) frames" : "")
                    + (summary.videosDeleted > 0 ? " · \(summary.videosDeleted) removed" : "")
                    + (summary.failures.isEmpty ? "" : " — \(summary.failures.count) failed"))
                box.code = summary.failures.isEmpty ? 0 : 1
            } catch {
                cliStderr("error: \(error.localizedDescription)\n")
                box.code = 1
            }
        }
        sem.wait()
        exit(Int32(box.code))
    }

    /// --embedder flag (persisted to cli-config) → saved cli-config → default.
    private static func resolveProvider(_ args: ParsedArgs) -> EmbeddingProvider {
        if let raw = args.value(for: "embedder")?.lowercased(),
           let p = EmbeddingProvider(rawValue: raw) {
            var cfg = CLIConfigStore.read()
            cfg.embeddingProvider = p.rawValue
            CLIConfigStore.write(cfg)
            return p
        }
        if let raw = CLIConfigStore.read().embeddingProvider,
           let p = EmbeddingProvider(rawValue: raw) {
            return p
        }
        return .local
    }

    private final class ReindexBox: @unchecked Sendable { var code: Int = 0 }
}
