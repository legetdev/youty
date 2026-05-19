import Foundation

// SQLite client for the Phase B vector index. Wraps the raw sqlite3 C API
// (no third-party packages). The DB lives at:
//   ~/Library/Application Support/Youty/index.db
// outside the synced vault, exactly as the spec mandates.
//
// Swift only writes the "base" tables (videos / chunks / frames /
// index_meta). The Python MCP server promotes these into vec0 + FTS5
// virtual tables on its own at startup, so the Swift binary stays free of
// the sqlite-vec extension.

enum IndexStoreError: LocalizedError {
    case schemaResourceMissing
    case open(code: Int32, message: String)
    case prepare(code: Int32, message: String, sql: String)
    case step(code: Int32, message: String, sql: String)
    case exec(code: Int32, message: String, sql: String)
    var errorDescription: String? {
        switch self {
        case .schemaResourceMissing:
            return "The search index template is missing from this build of Youty. Reinstall Youty to fix this."
        case .open:
            return "Couldn't open the search index. Try restarting Youty."
        case .prepare, .step, .exec:
            return "The search index ran into an error. Try the indexer again, or use Settings → Re-index vault if this keeps happening."
        }
    }
}

/// Plain-Swift mirror of a row in `videos`.
struct IndexVideoRow {
    let videoID:     String          // qualified, e.g. "yt:abc123"
    let platform:    String
    let title:       String
    let channel:     String?
    let url:         String
    let durationMs:  Int?
    let dateSavedMs: Int
    let folderPath:  String          // relative to vault root
    let tagsJSON:    String?         // JSON-encoded [String]
}

struct IndexChunkRow {
    let chunk: Chunk
    let embedding: [Float]
    let modelVersion: String
}

struct IndexFrameRow {
    let frameMs: Int
    let path: String                  // relative to vault root
    let phash: UInt64?
    let embedding: [Float]
    let modelVersion: String
}

/// Snapshot of the index state for the Settings UI. Read in one DB pass.
struct IndexStats: Sendable {
    let videoCount: Int
    let chunkCount: Int
    let frameCount: Int
    let lastRebuildMs: Int?           // unix epoch ms, nil if never rebuilt
    let textModelID: String?          // e.g. "gemini-embedding-001@768"
    let frameModelID: String?         // e.g. "siglip-base-patch16-224@768"
    let vaultRoot: String?
    let dbBytes: Int64                // index.db + index.db-wal size
}

/// Singleton; the indexer talks to one instance, opened lazily.
/// Internally serialises all writes via an actor — sqlite3 handles are not
/// safe to share across threads without serialised access.
actor IndexStore {

    static let shared = IndexStore()

    private var db: OpaquePointer?
    private var didBootstrap = false

    private init() {}

    // MARK: - Lifecycle

    /// Opens the database (creating parent dir + schema on first call).
    /// Safe to call repeatedly; subsequent calls are no-ops.
    func openIfNeeded() throws {
        if db != nil { return }
        let dbURL = try Self.defaultDatabaseURL()
        try FileManager.default.createDirectory(at: dbURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(dbURL.path, &handle, flags, nil)
        guard rc == SQLITE_OK, let opened = handle else {
            let msg = handle.flatMap { sqlite3_errmsg($0).flatMap { String(cString: $0) } } ?? "open failed"
            if let opened = handle { sqlite3_close_v2(opened) }
            throw IndexStoreError.open(code: rc, message: msg)
        }
        self.db = opened
        try bootstrap()
    }

    private func bootstrap() throws {
        guard !didBootstrap else { return }
        // Pragmas that need to come before schema.
        try exec("PRAGMA journal_mode = WAL;")
        try exec("PRAGMA synchronous  = NORMAL;")
        try exec("PRAGMA foreign_keys = ON;")
        try exec("PRAGMA busy_timeout = 5000;")

        guard let url = Bundle.main.url(forResource: "IndexSchema", withExtension: "sql"),
              let sql = try? String(contentsOf: url, encoding: .utf8) else {
            throw IndexStoreError.schemaResourceMissing
        }
        try exec(sql)
        didBootstrap = true
    }

    /// Closes the DB. Mainly for tests / headless runs.
    func close() {
        if let db { sqlite3_close_v2(db) }
        db = nil
        didBootstrap = false
    }

    // MARK: - Public writes

    /// Inserts or replaces the `videos` row.
    func upsertVideo(_ row: IndexVideoRow) throws {
        try openIfNeeded()
        let sql = """
        INSERT INTO videos
            (video_id, platform, title, channel, url, duration_ms,
             date_saved, folder_path, tags_json, indexed_at)
        VALUES (?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(video_id) DO UPDATE SET
            platform     = excluded.platform,
            title        = excluded.title,
            channel      = excluded.channel,
            url          = excluded.url,
            duration_ms  = excluded.duration_ms,
            date_saved   = excluded.date_saved,
            folder_path  = excluded.folder_path,
            tags_json    = excluded.tags_json,
            indexed_at   = excluded.indexed_at;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, row.videoID)
        bindText(stmt, 2, row.platform)
        bindText(stmt, 3, row.title)
        bindOptionalText(stmt, 4, row.channel)
        bindText(stmt, 5, row.url)
        bindOptionalInt(stmt, 6, row.durationMs)
        bindInt(stmt, 7, row.dateSavedMs)
        bindText(stmt, 8, row.folderPath)
        bindOptionalText(stmt, 9, row.tagsJSON)
        bindInt(stmt, 10, Int(Date().timeIntervalSince1970 * 1000))
        try step(stmt, sql: sql)
    }

    /// Atomically replaces every chunk row for `videoID`.
    func replaceChunks(videoID: String, rows: [IndexChunkRow]) throws {
        try openIfNeeded()
        try exec("BEGIN IMMEDIATE;")
        do {
            try execBound("DELETE FROM chunks WHERE video_id = ?;", text: videoID)
            let insertSQL = """
            INSERT INTO chunks
                (video_id, chunk_type, chunk_index, chunk_text,
                 chunk_start_ms, chunk_end_ms, model_version,
                 embedding_dim, embedding)
            VALUES (?,?,?,?,?,?,?,?,?);
            """
            let stmt = try prepare(insertSQL)
            defer { sqlite3_finalize(stmt) }
            for r in rows {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                bindText(stmt, 1, videoID)
                bindText(stmt, 2, r.chunk.type.rawValue)
                bindInt (stmt, 3, r.chunk.index)
                bindText(stmt, 4, r.chunk.text)
                bindOptionalInt(stmt, 5, r.chunk.startMs)
                bindOptionalInt(stmt, 6, r.chunk.endMs)
                bindText(stmt, 7, r.modelVersion)
                bindInt (stmt, 8, r.embedding.count)
                let blob = Self.floatsToLittleEndianData(r.embedding)
                bindBlob(stmt, 9, blob)
                try step(stmt, sql: insertSQL)
            }
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    /// Atomically replaces every frame row for `videoID`.
    func replaceFrames(videoID: String, rows: [IndexFrameRow]) throws {
        try openIfNeeded()
        try exec("BEGIN IMMEDIATE;")
        do {
            try execBound("DELETE FROM frames WHERE video_id = ?;", text: videoID)
            let insertSQL = """
            INSERT INTO frames
                (video_id, frame_ms, frame_path, phash, model_version,
                 embedding_dim, embedding)
            VALUES (?,?,?,?,?,?,?);
            """
            let stmt = try prepare(insertSQL)
            defer { sqlite3_finalize(stmt) }
            for r in rows {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                bindText(stmt, 1, videoID)
                bindInt (stmt, 2, r.frameMs)
                bindText(stmt, 3, r.path)
                if let h = r.phash {
                    // Store as signed 64-bit (SQLite has no unsigned). Round-trip is bit-exact via Int64(bitPattern:).
                    sqlite3_bind_int64(stmt, 4, sqlite3_int64(Int64(bitPattern: h)))
                } else {
                    sqlite3_bind_null(stmt, 4)
                }
                bindText(stmt, 5, r.modelVersion)
                bindInt (stmt, 6, r.embedding.count)
                let blob = Self.floatsToLittleEndianData(r.embedding)
                bindBlob(stmt, 7, blob)
                try step(stmt, sql: insertSQL)
            }
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    /// Deletes a video and (via FK cascade) all its chunks / frames.
    func deleteVideo(videoID: String) throws {
        try openIfNeeded()
        try execBound("DELETE FROM videos WHERE video_id = ?;", text: videoID)
    }

    /// Drops every `frames` row whose `model_version` doesn't match the
    /// caller's current frame-model identifier, then records that
    /// identifier in `index_meta`. Called once per app session at the
    /// start of any frame-indexing path — if the binary has been
    /// upgraded to a new frame model (e.g. MobileCLIP-S2 → SigLIP),
    /// existing vectors live in a different embedding space and must be
    /// re-computed before any retrieval can correctly compare new query
    /// embeddings against them. Idempotent — once the table is purged,
    /// subsequent calls are no-ops because the rows now all match.
    /// Returns the number of stale rows dropped (for logging).
    @discardableResult
    func purgeStaleFrameVectors(currentModel: String) throws -> Int {
        try openIfNeeded()
        let countSQL = "SELECT COUNT(*) FROM frames WHERE model_version <> ?;"
        let countStmt = try prepare(countSQL)
        bindText(countStmt, 1, currentModel)
        var stale = 0
        if sqlite3_step(countStmt) == SQLITE_ROW {
            stale = Int(sqlite3_column_int64(countStmt, 0))
        }
        sqlite3_finalize(countStmt)
        if stale > 0 {
            try execBound("DELETE FROM frames WHERE model_version <> ?;", text: currentModel)
        }
        // Always advance the meta key so the next session sees the right value.
        try setMeta(key: "current_frame_model", value: currentModel)
        return stale
    }

    /// Aggregate stats for the Settings UI. Single round-trip through the
    /// DB — counts + the relevant `index_meta` rows + file size.
    func indexStats() throws -> IndexStats {
        try openIfNeeded()
        func count(_ table: String) -> Int {
            let stmt = try? prepare("SELECT COUNT(*) FROM \(table);")
            defer { sqlite3_finalize(stmt) }
            if let stmt, sqlite3_step(stmt) == SQLITE_ROW {
                return Int(sqlite3_column_int64(stmt, 0))
            }
            return 0
        }
        func meta(_ key: String) -> String? {
            let stmt = try? prepare("SELECT value FROM index_meta WHERE key = ?;")
            defer { sqlite3_finalize(stmt) }
            guard let stmt else { return nil }
            bindText(stmt, 1, key)
            if sqlite3_step(stmt) == SQLITE_ROW, let cstr = sqlite3_column_text(stmt, 0) {
                return String(cString: cstr)
            }
            return nil
        }
        let videoCount = count("videos")
        let chunkCount = count("chunks")
        let frameCount = count("frames")
        let lastRebuildMs = meta("last_rebuild").flatMap(Int.init)
        let textModel = meta("current_text_model")
        let frameModel = meta("current_frame_model")
        let vaultRoot = meta("vault_root")

        // DB file size (includes WAL sidecar if present).
        var dbBytes: Int64 = 0
        if let path = try? Self.databasePath() {
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            if let n = attrs?[.size] as? NSNumber { dbBytes += n.int64Value }
            let wal = path + "-wal"
            if let walAttrs = try? FileManager.default.attributesOfItem(atPath: wal),
               let n = walAttrs[.size] as? NSNumber { dbBytes += n.int64Value }
        }
        return IndexStats(
            videoCount:    videoCount,
            chunkCount:    chunkCount,
            frameCount:    frameCount,
            lastRebuildMs: lastRebuildMs,
            textModelID:   textModel,
            frameModelID:  frameModel,
            vaultRoot:     vaultRoot,
            dbBytes:       dbBytes
        )
    }

    /// Returns every `video_id` currently in the index. Used by the reindex
    /// sweep to find rows orphaned by on-disk deletions.
    func allVideoIDs() throws -> [String] {
        try openIfNeeded()
        let sql = "SELECT video_id FROM videos;"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cstr = sqlite3_column_text(stmt, 0) {
                out.append(String(cString: cstr))
            }
        }
        return out
    }

    /// Returns (indexed_at_ms, chunk_count) for a video, or nil if unindexed.
    /// Used by the indexer to skip re-embedding videos whose video.md hasn't
    /// been modified since the last successful index — keeps reindex idempotent
    /// and avoids burning embed-API quota on no-op work.
    func videoIndexState(videoID: String) throws -> (indexedAt: Int, chunkCount: Int, modelVersion: String?)? {
        try openIfNeeded()
        let sql = """
            SELECT v.indexed_at,
                   (SELECT COUNT(*) FROM chunks WHERE video_id = v.video_id) AS cnt,
                   (SELECT model_version FROM chunks WHERE video_id = v.video_id LIMIT 1) AS mv
            FROM videos v WHERE v.video_id = ?;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, videoID)
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_ROW {
            let at = Int(sqlite3_column_int64(stmt, 0))
            let cnt = Int(sqlite3_column_int64(stmt, 1))
            let mvPtr = sqlite3_column_text(stmt, 2)
            let mv = mvPtr.flatMap { String(cString: $0) }
            return (at, cnt, mv)
        }
        return nil
    }

    /// Convenience: updates an `index_meta` key.
    func setMeta(key: String, value: String) throws {
        try openIfNeeded()
        let sql = "INSERT INTO index_meta(key,value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value;"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, key)
        bindText(stmt, 2, value)
        try step(stmt, sql: sql)
    }

    /// Returns the absolute on-disk path of the index DB. Useful for the
    /// headless `--reindex` smoke test and for surfacing the location in
    /// Settings.
    static func databasePath() throws -> String {
        return try defaultDatabaseURL().path
    }

    // MARK: - Path

    private static func defaultDatabaseURL() throws -> URL {
        let appSupport = try FileManager.default.url(for: .applicationSupportDirectory,
                                                      in: .userDomainMask,
                                                      appropriateFor: nil,
                                                      create: true)
        return appSupport
            .appendingPathComponent("Youty", isDirectory: true)
            .appendingPathComponent("index.db")
    }

    // MARK: - sqlite3 helpers

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        guard let db else {
            throw IndexStoreError.open(code: 0, message: "database not open")
        }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw IndexStoreError.prepare(code: rc, message: msg, sql: sql)
        }
        return stmt
    }

    private func step(_ stmt: OpaquePointer?, sql: String) throws {
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            let msg = db.flatMap { sqlite3_errmsg($0).flatMap { String(cString: $0) } } ?? "step failed"
            throw IndexStoreError.step(code: rc, message: msg, sql: sql)
        }
    }

    /// Executes a multi-statement SQL string. Used for bootstrap + pragma.
    private func exec(_ sql: String) throws {
        guard let db else {
            throw IndexStoreError.open(code: 0, message: "database not open")
        }
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.flatMap { String(cString: $0) } ?? "exec failed"
            if let err { sqlite3_free(err) }
            throw IndexStoreError.exec(code: rc, message: msg, sql: sql)
        }
    }

    /// One-shot bound DELETE / UPDATE — used inside the transaction wrappers.
    private func execBound(_ sql: String, text: String) throws {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, text)
        try step(stmt, sql: sql)
    }

    // MARK: - Binding

    private static let SQLITE_TRANSIENT_BRIDGE = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)

    private func bindText(_ stmt: OpaquePointer?, _ idx: Int32, _ v: String) {
        let cstr = (v as NSString).utf8String
        sqlite3_bind_text(stmt, idx, cstr, -1, Self.SQLITE_TRANSIENT_BRIDGE)
    }
    private func bindOptionalText(_ stmt: OpaquePointer?, _ idx: Int32, _ v: String?) {
        if let v { bindText(stmt, idx, v) } else { sqlite3_bind_null(stmt, idx) }
    }
    private func bindInt(_ stmt: OpaquePointer?, _ idx: Int32, _ v: Int) {
        sqlite3_bind_int64(stmt, idx, sqlite3_int64(v))
    }
    private func bindOptionalInt(_ stmt: OpaquePointer?, _ idx: Int32, _ v: Int?) {
        if let v { bindInt(stmt, idx, v) } else { sqlite3_bind_null(stmt, idx) }
    }
    private func bindBlob(_ stmt: OpaquePointer?, _ idx: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            sqlite3_bind_blob(stmt, idx, raw.baseAddress, Int32(data.count), Self.SQLITE_TRANSIENT_BRIDGE)
        }
    }

    // MARK: - Embedding serialization

    /// Serialises a Float vector to little-endian fp32 bytes, exactly as the
    /// `chunks.embedding` / `frames.embedding` BLOB columns expect.
    static func floatsToLittleEndianData(_ floats: [Float]) -> Data {
        var data = Data(count: floats.count * 4)
        data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            for (i, f) in floats.enumerated() {
                let bits = f.bitPattern.littleEndian
                let dst = base.advanced(by: i * 4)
                memcpy(dst, [bits], 4)
            }
        }
        return data
    }
}
