import Foundation

// `youty reindex` — rebuilds the local search index for the resolved vault.
//
// Default: full (text + frames). `--text-only` re-embeds just transcript text
// (the fast Phase S.4 path; frames keep their SigLIP vectors). All embedding is
// on-device — no key, no cloud.
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
        let textOnly = args.bool("text-only")
        let quiet = args.bool("quiet") || args.bool("q")
        let vaultURL = vaultResolution.url

        if !quiet {
            cliStderr("• Vault: \(vaultURL.path) (from \(vaultResolution.source.label))\n")
            cliStderr("• Re-embedding \(textOnly ? "text only" : "text + frames") on-device…\n")
        }

        let sem = DispatchSemaphore(value: 0)
        let box = ReindexBox()
        Task.detached {
            defer { sem.signal() }
            do {
                let embedder = try Indexer.makeEmbedder()
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

    private final class ReindexBox: @unchecked Sendable { var code: Int = 0 }
}
