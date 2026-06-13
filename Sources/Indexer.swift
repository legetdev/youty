import Foundation

// Orchestrates the Phase B write pipeline:
//   video.md on disk → Chunker → Embedder → IndexStore (SQLite).
//
// Indexer is NOT @MainActor — it's a pure background task. The two hooks
// in ContentView (post-runFramePipeline and post-pipeline.save) dispatch
// it with Task.detached so indexing never blocks the UI.

enum IndexerError: LocalizedError {
    case missingKey
    case localModelUnavailable
    case vaultMismatch(String)
    case noVideoMD(URL)
    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "Add a Gemini API key in Settings → AI search index, or switch the embedding provider to On-device, to enable transcript search."
        case .localModelUnavailable:
            return "The on-device search model isn't installed. Reinstall Youty (or re-run the CLI installer) to enable local transcript search — or switch to Gemini in Settings → AI search index."
        case .vaultMismatch(let message):
            return message
        case .noVideoMD:
            return "This saved video is missing its note file. The original save may have failed — try saving again."
        }
    }
}

/// Outcome of a full-vault re-index, surfaced to the UI / CLI.
struct ReindexSummary: Sendable {
    var videosIndexed: Int = 0
    var chunksWritten: Int = 0
    var videosDeleted: Int = 0       // bundles in DB whose video.md is gone from disk
    var framesKept: Int = 0          // frames re-embedded in this run (0 if frame index skipped)
    var framesDroppedDedupe: Int = 0 // pHash-filtered duplicates dropped during frame re-embed
    var failures: [(folder: String, error: String)] = []
    var totalMs: Int = 0
}

/// Outcome of a vault frame-only reindex.
struct FrameReindexSummary: Sendable {
    var videosProcessed: Int = 0
    var videosSkipped: Int = 0          // bundles with 0 8-digit-ms JPEGs
    var framesKept: Int = 0
    var framesDroppedDedupe: Int = 0
    var failures: [(folder: String, error: String)] = []
    var totalMs: Int = 0
}

enum Indexer {

    /// Indexes a single freshly-saved bundle. `videoMdURL` must point at the
    /// bundle's `video.md`; `vaultRoot` is needed to compute `folder_path`
    /// (which is stored relative to vault root, not absolute).
    static func indexBundle(videoMdURL: URL, vaultRoot: URL) async throws {
        try await indexBundle(videoMdURL: videoMdURL,
                              vaultRoot: vaultRoot,
                              embedder: try makeDefaultEmbedder())
    }

    /// Indexes every `video.md` under `vaultRoot`. Used by the Settings
    /// re-index button and by `--reindex` headless mode.
    ///
    /// Also synchronises deletions: at the end of the walk, any DB row whose
    /// `video_id` was NOT seen on disk in this run is deleted (cascade clears
    /// chunks, frames, vec_chunks, vec_frames, FTS5). Then drops a refreshed
    /// version of the bundles' video_ids into `index_meta.last_seen_ids` for
    /// later diagnostics.
    @discardableResult
    static func reindexVault(vaultRoot: URL,
                              progress: ((String) -> Void)? = nil) async throws -> ReindexSummary {
        let kickoff = Date()
        let embedder = try makeEmbedderOrThrow()
        let bundles = enumerateBundles(at: vaultRoot)
        var summary = ReindexSummary()
        var seenIDs = Set<String>()
        for url in bundles {
            do {
                let count = try await indexBundle(videoMdURL: url,
                                                   vaultRoot: vaultRoot,
                                                   embedder: embedder)
                summary.videosIndexed += 1
                summary.chunksWritten += count
                if let id = try? Chunker.parseAndChunk(videoMdURL: url).parsed.qualifiedID {
                    seenIDs.insert(id)
                }
                if count == 0 {
                    progress?("SKIP \(url.path) — already indexed, video.md unchanged")
                } else {
                    progress?("OK \(url.path) — \(count) chunks")
                }
            } catch {
                let rel = url.path.replacingOccurrences(of: vaultRoot.path + "/", with: "")
                summary.failures.append((folder: rel, error: error.localizedDescription))
                progress?("FAIL \(rel) — \(error.localizedDescription)")
            }
        }

        // Sync deletions — drop DB rows for bundles that no longer exist on
        // disk. Cascade deletes chunks + frames + their vec0 partitions + the
        // FTS5 rows via the schema's ON DELETE CASCADE.
        let allIDs = (try? await IndexStore.shared.allVideoIDs()) ?? []
        for id in allIDs where !seenIDs.contains(id) {
            do {
                try await IndexStore.shared.deleteVideo(videoID: id)
                summary.videosDeleted += 1
                progress?("DELETE \(id) — video.md no longer on disk")
            } catch {
                progress?("FAIL_DELETE \(id) — \(error.localizedDescription)")
            }
        }

        // Rebuild manifest.json so the on-disk corpus index also reflects
        // the new state (deletions + folder renames). `rebuildManifest` is
        // nonisolated so this can run directly on the background task; no
        // MainActor hop required (which would deadlock the headless probe
        // that blocks main on `sem.wait()`).
        let manifestTouched = VaultManager.rebuildManifest(at: vaultRoot)
        progress?("MANIFEST_REBUILT=\(manifestTouched)")

        // Frame re-embed pass — "Re-index entire vault" must re-cover
        // frame search too, especially after a model swap (e.g. the
        // MobileCLIP → SigLIP migration in R.0b). Without this, the
        // text index gets rebuilt cleanly but `search_frames` returns
        // nothing until the user runs the CLI re-index probe by hand.
        // Idempotent at the bundle level via `purgeStaleFrameVectors`
        // — bundles already embedded under the current model identifier
        // are no-ops; bundles under a stale identifier are re-embedded
        // here once and then become no-ops on subsequent calls.
        progress?("FRAME_REINDEX_START")
        let frameSummary = try await reindexFrames(vaultRoot: vaultRoot,
                                                    progress: progress)
        summary.framesKept = frameSummary.framesKept
        summary.framesDroppedDedupe = frameSummary.framesDroppedDedupe
        for f in frameSummary.failures {
            summary.failures.append(f)
        }
        progress?("FRAME_REINDEX_DONE kept=\(frameSummary.framesKept) dropped=\(frameSummary.framesDroppedDedupe)")

        summary.totalMs = Int(Date().timeIntervalSince(kickoff) * 1000)

        // Record vault path + last rebuild so the MCP server / Settings UI
        // can show "indexed against {path} at {time}".
        try? await IndexStore.shared.setMeta(key: "vault_root", value: vaultRoot.path)
        try? await IndexStore.shared.setMeta(key: "last_rebuild",
                                              value: "\(Int(Date().timeIntervalSince1970 * 1000))")
        return summary
    }

    // MARK: - Internal: single-bundle path

    /// Returns the chunk count it wrote, so reindexVault can sum it up.
    /// Returns 0 when the bundle is already up-to-date (idempotent skip:
    /// video.md mtime <= last indexed_at AND model_version matches).
    @discardableResult
    static func indexBundle(videoMdURL: URL,
                             vaultRoot: URL,
                             embedder: Embedder,
                             force: Bool = false) async throws -> Int {
        let started = Date()
        let fm = FileManager.default
        guard fm.fileExists(atPath: videoMdURL.path) else {
            throw IndexerError.noVideoMD(videoMdURL)
        }

        let (parsed, chunks) = try Chunker.parseAndChunk(videoMdURL: videoMdURL)
        guard !parsed.videoID.isEmpty else {
            throw IndexerError.vaultMismatch("video.md has no video_id / post_id field")
        }
        guard !chunks.isEmpty else {
            return 0
        }

        // Always refresh the videos row first — keeps folder_path / title /
        // tags / channel in sync with what's on disk RIGHT NOW, even when
        // we're about to skip re-embedding. Decouples metadata freshness
        // from chunk freshness.
        let bundleFolder = videoMdURL.deletingLastPathComponent()
        let folderPath = relativePath(of: bundleFolder, under: vaultRoot)
        let tagsJSON: String = {
            guard !parsed.tags.isEmpty else { return "[]" }
            if let data = try? JSONSerialization.data(withJSONObject: parsed.tags, options: []),
               let str = String(data: data, encoding: .utf8) { return str }
            return "[]"
        }()
        let videoRow = IndexVideoRow(
            videoID:     parsed.qualifiedID,
            platform:    parsed.platform,
            title:       parsed.title,
            channel:     parsed.channel.isEmpty ? nil : parsed.channel,
            url:         parsed.url,
            durationMs:  parsed.durationMs,
            dateSavedMs: parsed.dateSavedUnixMs,
            folderPath:  folderPath,
            tagsJSON:    tagsJSON
        )
        try await IndexStore.shared.upsertVideo(videoRow)

        // Idempotent skip — don't burn quota on already-indexed videos.
        if !force,
           let state = try await IndexStore.shared.videoIndexState(videoID: parsed.qualifiedID),
           state.chunkCount > 0,
           state.modelVersion == embedder.modelIdentifier {
            let attrs = try? fm.attributesOfItem(atPath: videoMdURL.path)
            let mtimeMs = (attrs?[.modificationDate] as? Date).map { Int($0.timeIntervalSince1970 * 1000) } ?? 0
            if mtimeMs <= state.indexedAt {
                return 0
            }
        }

        // Embed all chunks in one batch (Gemini batch endpoint handles ≥2,
        // single endpoint for 1).
        let inputs = chunks.map { $0.embeddingInput }
        let vectors = try await embedder.embed(inputs)
        guard vectors.count == chunks.count else {
            throw IndexerError.vaultMismatch("embedder returned \(vectors.count) vectors for \(chunks.count) chunks")
        }

        let chunkRows: [IndexChunkRow] = zip(chunks, vectors).map { (c, v) in
            IndexChunkRow(chunk: c, embedding: v, modelVersion: embedder.modelIdentifier)
        }

        let store = IndexStore.shared
        try await store.replaceChunks(videoID: videoRow.videoID, rows: chunkRows)
        try await store.setMeta(key: "current_text_model", value: embedder.modelIdentifier)

        let ms = Int(Date().timeIntervalSince(started) * 1000)
        NSLog("[indexer] %@ chunks=%d in %dms", videoRow.videoID, chunkRows.count, ms)
        return chunkRows.count
    }

    // MARK: - Frame indexing

    /// Indexes frames for a single bundle. Returns (kept, dropped) counts.
    /// Bundles with 0 8-digit-ms JPEGs (legacy 4-digit-seconds format)
    /// are silently skipped — they predate the millisecond convention and
    /// we don't break on real-world legacy data.
    @discardableResult
    static func indexFrames(videoMdURL: URL,
                             vaultRoot: URL) async throws -> (kept: Int, dropped: Int) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: videoMdURL.path) else {
            throw IndexerError.noVideoMD(videoMdURL)
        }
        let (parsed, _) = try Chunker.parseAndChunk(videoMdURL: videoMdURL)
        guard !parsed.videoID.isEmpty else {
            throw IndexerError.vaultMismatch("video.md has no video_id / post_id field")
        }

        // Purge any frame rows embedded by an older model (e.g. a vault
        // indexed with MobileCLIP-S2 before the SigLIP migration). The
        // call is idempotent — after the first save under the new model
        // every row matches and this becomes a no-op COUNT(*) query.
        // Without this, mixed-model vectors would coexist in vec_frames
        // and silently degrade `search_frames` retrieval quality.
        _ = try? await IndexStore.shared.purgeStaleFrameVectors(
            currentModel: siglipModelIdentifier
        )

        let bundleFolder = videoMdURL.deletingLastPathComponent()
        let folderPath = relativePath(of: bundleFolder, under: vaultRoot)

        // Enumerate JPEGs whose stem is pure digits AND ≥8 chars (millisecond
        // format). 4-digit legacy filenames are skipped silently.
        let entries = (try? fm.contentsOfDirectory(at: bundleFolder,
                                                    includingPropertiesForKeys: nil)) ?? []
        let jpegs: [(ms: Int, url: URL)] = entries.compactMap { url in
            guard url.pathExtension.lowercased() == "jpg" else { return nil }
            let stem = url.deletingPathExtension().lastPathComponent
            guard stem.count >= 8, stem.allSatisfy({ $0.isNumber }), let ms = Int(stem) else { return nil }
            return (ms, url)
        }.sorted { $0.ms < $1.ms }

        guard !jpegs.isEmpty else {
            return (0, 0)
        }

        // pHash filter — drop near-duplicate frames (slide-heavy content
        // typically halves; talking-head content barely changes).
        let urls = jpegs.map { $0.url }
        let keepIdx = PHashFilter.keepIndices(jpegURLs: urls)
        let keptInputs: [(ms: Int, url: URL)] = keepIdx.map { jpegs[$0] }
        let droppedCount = jpegs.count - keptInputs.count

        // Embed kept frames in one pass through CoreML.
        let urlsKept = keptInputs.map { $0.url }
        let vectors = try await FrameEmbedder.embedFrames(urlsKept)
        guard vectors.count == keptInputs.count else {
            throw IndexerError.vaultMismatch(
                "frame embedder returned \(vectors.count) vectors for \(keptInputs.count) frames")
        }

        // Build IndexFrameRow with phash (cheap second pass on kept frames).
        let rows: [IndexFrameRow] = zip(keptInputs, vectors).map { (k, v) in
            let phash = PHashFilter.phash(at: k.url)
            let rel = "\(folderPath)/\(k.url.lastPathComponent)"
            return IndexFrameRow(frameMs: k.ms,
                                 path: rel,
                                 phash: phash,
                                 embedding: v,
                                 modelVersion: siglipModelIdentifier)
        }

        // Ensure a `videos` row exists for FK satisfaction. If the bundle has
        // never been text-indexed (e.g. no Gemini key configured), we still
        // want frame indexing to succeed — frames are independently useful.
        let tagsJSON: String = {
            guard !parsed.tags.isEmpty else { return "[]" }
            if let data = try? JSONSerialization.data(withJSONObject: parsed.tags, options: []),
               let str = String(data: data, encoding: .utf8) { return str }
            return "[]"
        }()
        let videoRow = IndexVideoRow(
            videoID:     parsed.qualifiedID,
            platform:    parsed.platform,
            title:       parsed.title,
            channel:     parsed.channel.isEmpty ? nil : parsed.channel,
            url:         parsed.url,
            durationMs:  parsed.durationMs,
            dateSavedMs: parsed.dateSavedUnixMs,
            folderPath:  folderPath,
            tagsJSON:    tagsJSON
        )
        try await IndexStore.shared.upsertVideo(videoRow)
        try await IndexStore.shared.replaceFrames(videoID: parsed.qualifiedID, rows: rows)
        try? await IndexStore.shared.setMeta(key: "current_frame_model",
                                              value: siglipModelIdentifier)
        return (rows.count, droppedCount)
    }

    /// Walks the vault and runs `indexFrames` over every bundle.
    @discardableResult
    static func reindexFrames(vaultRoot: URL,
                               progress: ((String) -> Void)? = nil) async throws -> FrameReindexSummary {
        let kickoff = Date()
        let bundles = enumerateBundles(at: vaultRoot)
        var summary = FrameReindexSummary()
        for url in bundles {
            do {
                let (kept, dropped) = try await indexFrames(videoMdURL: url, vaultRoot: vaultRoot)
                if kept == 0 && dropped == 0 {
                    summary.videosSkipped += 1
                    progress?("SKIP \(url.path) — no millisecond-named JPEGs (legacy bundle)")
                } else {
                    summary.videosProcessed += 1
                    summary.framesKept += kept
                    summary.framesDroppedDedupe += dropped
                    progress?("OK \(url.path) — kept=\(kept) dropped=\(dropped)")
                }
            } catch {
                let rel = url.path.replacingOccurrences(of: vaultRoot.path + "/", with: "")
                summary.failures.append((folder: rel, error: error.localizedDescription))
                progress?("FAIL \(rel) — \(error.localizedDescription)")
            }
        }
        summary.totalMs = Int(Date().timeIntervalSince(kickoff) * 1000)
        try? await IndexStore.shared.setMeta(key: "vault_root", value: vaultRoot.path)
        return summary
    }

    // MARK: - Embedder selection

    /// Builds the text embedder for `provider`. Throws when that provider's
    /// backing is unavailable — the on-device model files are missing, or
    /// Gemini is selected without a key. It NEVER silently substitutes the
    /// other provider: doing so would split the index across two embedding
    /// spaces and silently corrupt search. Callers surface the thrown error.
    static func makeEmbedder(for provider: EmbeddingProvider) throws -> Embedder {
        switch provider {
        case .local:
            do {
                return try EmbeddingGemmaEmbedder()
            } catch {
                throw IndexerError.localModelUnavailable
            }
        case .gemini:
            guard KeychainHelper.exists(account: "youty", service: "gemini-api") else {
                throw IndexerError.missingKey
            }
            return GeminiEmbedder()
        }
    }

    /// The embedder for the app's current `embeddingProvider` setting
    /// (default on-device). Read from UserDefaults so it works off the
    /// main actor inside the background indexing task.
    private static func makeDefaultEmbedder() throws -> Embedder {
        try makeEmbedder(for: .current)
    }

    /// Used by reindexVault — pre-flights the embedder once so the user
    /// gets a single clear error instead of N failed per-bundle calls.
    private static func makeEmbedderOrThrow() throws -> Embedder {
        try makeEmbedder(for: .current)
    }

    // MARK: - Vault walking

    private static func enumerateBundles(at vaultRoot: URL) -> [URL] {
        let fm = FileManager.default
        var bundles: [URL] = []
        // Per-platform subfolders. We also tolerate legacy bundles directly
        // under the vault root (pre-platform-subfolder vaults).
        let platformDirs = ["youtube", "instagram", "tiktok"]
        for p in platformDirs {
            let dir = vaultRoot.appendingPathComponent(p)
            guard let inner = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
            for bundle in inner {
                let md = bundle.appendingPathComponent("video.md")
                if fm.fileExists(atPath: md.path) { bundles.append(md) }
            }
        }
        // Legacy flat bundles.
        if let inner = try? fm.contentsOfDirectory(at: vaultRoot, includingPropertiesForKeys: [.isDirectoryKey]) {
            for bundle in inner {
                let name = bundle.lastPathComponent
                if Set(platformDirs).contains(name) { continue }
                let md = bundle.appendingPathComponent("video.md")
                if fm.fileExists(atPath: md.path) { bundles.append(md) }
            }
        }
        return bundles
    }

    private static func relativePath(of folder: URL, under vaultRoot: URL) -> String {
        let folderPath = folder.standardizedFileURL.path
        let rootPath = vaultRoot.standardizedFileURL.path
        if folderPath.hasPrefix(rootPath + "/") {
            return String(folderPath.dropFirst(rootPath.count + 1))
        }
        return folder.lastPathComponent
    }
}
