import Foundation

// SQLite client for the Phase B vector index. Wraps the raw sqlite3 C API
// (no third-party packages). The DB lives at:
//   ~/Library/Application Support/Youty/index.db
// outside the synced vault, exactly as the spec mandates.
//
// macOS blocks other programs from reading a sandboxed app's container unless
// the user grants them "access data from other apps" or Full Disk Access. So
// after indexing, the app publishes a read-only copy of the base tables to
// `{vault}/.youty/index.db` (`publishSnapshot`), which the MCP server reads
// without any extra permission. The copy is written to a temp file and renamed
// into place, so readers and file-sync tools only ever see a complete file.
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
    let textModelID: String?          // e.g. "embeddinggemma-300m@768"
    let frameModelID: String?         // e.g. "embeddinggemma-2@768"
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
    private let databaseURL: URL?

    /// `databaseURL` is for tests; the app and CLI use `shared`.
    init(databaseURL: URL? = nil) {
        self.databaseURL = databaseURL
    }

    private func databaseFileURL() throws -> URL {
        try databaseURL ?? Self.defaultDatabaseURL()
    }

    // MARK: - Lifecycle

    /// Opens the database (creating parent dir + schema on first call).
    /// Safe to call repeatedly; subsequent calls are no-ops.
    func openIfNeeded() throws {
        if db != nil { return }
        let dbURL = try databaseFileURL()
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

        // App resolves the schema from its own bundle. The CLI is a bare
        // tool binary with no Resources/, so fall back to the shared
        // install location populated by Scripts/install-cli.sh.
        let schemaURL = Bundle.main.url(forResource: "IndexSchema", withExtension: "sql")
            ?? SharedResourceLocator.url(named: "IndexSchema", extensions: ["sql"])
        guard let schemaURL,
              let sql = try? String(contentsOf: schemaURL, encoding: .utf8) else {
            throw IndexStoreError.schemaResourceMissing
        }
        try exec(sql)
        try migrateSchemaIfNeeded()
        // Identifies this index across its published copies, so a reader can tell
        // a newer copy of the same index from a different one (other Mac, reset).
        try exec("INSERT OR IGNORE INTO index_meta(key, value) VALUES ('index_id', lower(hex(randomblob(16))));")
        try purgeOrphans()
        Self.removeLegacySecrets(nextTo: try databaseFileURL())
        didBootstrap = true
    }

    /// Chunk and frame rows whose video row is gone are unreachable (search
    /// hydrates through `videos`) yet still occupy keyword and vector pools.
    /// The v1→v2 rebuild deliberately carried such rows over, so drop them on
    /// every open; with no orphans this is two indexed no-op deletes.
    private func purgeOrphans() throws {
        try exec("""
        DELETE FROM chunks WHERE video_id NOT IN (SELECT video_id FROM videos);
        DELETE FROM frames WHERE video_id NOT IN (SELECT video_id FROM videos);
        """)
    }

    /// Youty once stored a cloud embedding API key as plain text beside the
    /// index. Search is on-device now and nothing reads it, so remove it.
    nonisolated static func removeLegacySecrets(nextTo dbURL: URL) {
        let legacyKey = dbURL.deletingLastPathComponent().appendingPathComponent(".gemini-api.key")
        try? FileManager.default.removeItem(at: legacyKey)
    }

    /// One-time, idempotent schema migrations for index DBs created by an older
    /// build. v1→v2 introduces the `frame_text` chunk type (OCR'd on-screen
    /// text), which requires relaxing the `chunks.chunk_type` CHECK constraint.
    /// SQLite can't ALTER a CHECK, so we rebuild the table **preserving
    /// chunk_id** — that keeps the MCP's vec0 + FTS5 shadow tables (both keyed on
    /// chunk_id) valid, so no full re-embed is forced. Data is fully preserved.
    private func migrateSchemaIfNeeded() throws {
        let version = Int(scalarText("SELECT value FROM index_meta WHERE key='schema_version';") ?? "0") ?? 0
        if version >= 2 { return }
        // A table rebuild must run with foreign_keys OFF: the old chunks table can
        // hold orphan rows (video_id no longer in `videos`), and copying them into
        // the new FK-enforced table fails with FK ON. The pragma is a no-op inside
        // a transaction, so toggle it OUTSIDE the BEGIN/COMMIT — and always
        // restore it, even on failure.
        try exec("PRAGMA foreign_keys=OFF;")
        let migrate = """
        BEGIN IMMEDIATE;
        ALTER TABLE chunks RENAME TO chunks_v1_old;
        CREATE TABLE chunks (
            chunk_id        INTEGER PRIMARY KEY AUTOINCREMENT,
            video_id        TEXT    NOT NULL REFERENCES videos(video_id) ON DELETE CASCADE,
            chunk_type      TEXT    NOT NULL CHECK (chunk_type IN ('header','description','body','frame_text')),
            chunk_index     INTEGER NOT NULL,
            chunk_text      TEXT    NOT NULL,
            chunk_start_ms  INTEGER,
            chunk_end_ms    INTEGER,
            model_version   TEXT    NOT NULL,
            embedding_dim   INTEGER NOT NULL,
            embedding       BLOB    NOT NULL,
            UNIQUE(video_id, chunk_type, chunk_index)
        );
        INSERT INTO chunks (chunk_id, video_id, chunk_type, chunk_index, chunk_text,
                            chunk_start_ms, chunk_end_ms, model_version, embedding_dim, embedding)
            SELECT chunk_id, video_id, chunk_type, chunk_index, chunk_text,
                   chunk_start_ms, chunk_end_ms, model_version, embedding_dim, embedding
            FROM chunks_v1_old;
        DROP TABLE chunks_v1_old;
        CREATE INDEX IF NOT EXISTS idx_chunks_video ON chunks(video_id);
        CREATE INDEX IF NOT EXISTS idx_chunks_type  ON chunks(chunk_type);
        CREATE INDEX IF NOT EXISTS idx_chunks_model ON chunks(model_version);
        UPDATE index_meta SET value='2' WHERE key='schema_version';
        COMMIT;
        """
        do {
            try exec(migrate)
        } catch {
            try? exec("ROLLBACK;")
            try? exec("PRAGMA foreign_keys=ON;")
            throw error
        }
        try exec("PRAGMA foreign_keys=ON;")
    }

    /// True if the index already holds OCR'd on-screen-text chunks for a video.
    /// Used by the V.1 backfill to tell a fully-indexed bundle from one whose
    /// `## On-screen text` section was written but not yet indexed.
    func hasFrameTextChunks(videoID: String) throws -> Bool {
        try openIfNeeded()
        let stmt = try prepare("SELECT 1 FROM chunks WHERE video_id = ? AND chunk_type = 'frame_text' LIMIT 1;")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, videoID)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    /// The first spoken-transcript chunk's text, or nil when the video has none.
    func firstBodyChunkText(videoID: String) throws -> String? {
        try openIfNeeded()
        let stmt = try prepare("SELECT chunk_text FROM chunks WHERE video_id = ? AND chunk_type = 'body' ORDER BY chunk_index LIMIT 1;")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, videoID)
        guard sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: c)
    }

    /// Reads a single text value from a no-arg query (nil if no row/NULL).
    private func scalarText(_ sql: String) -> String? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: c)
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
            tags_json    = excluded.tags_json;
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
            // indexed_at means "transcript chunks written", so only this sets it:
            // refreshing a video's metadata (upsertVideo, frame indexing) must not
            // make a note edited since its chunks were written look current.
            let stampSQL = "UPDATE videos SET indexed_at = ? WHERE video_id = ?;"
            let stamp = try prepare(stampSQL)
            defer { sqlite3_finalize(stamp) }
            bindInt(stamp, 1, Int(Date().timeIntervalSince1970 * 1000))
            bindText(stamp, 2, videoID)
            try step(stamp, sql: stampSQL)
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

    /// How much of the text index is NOT on `activeModel` — i.e. what a
    /// provider switch would need to re-embed. Returns the count of distinct
    /// videos and of chunks whose `model_version` differs. Both zero ⇒ the
    /// index already matches the active model (no migration needed). Frames
    /// are counted separately (see `needsModelMigration`).
    func textMigrationScope(activeModel: String) throws -> (videos: Int, chunks: Int) {
        try openIfNeeded()
        // JOIN videos so only real, disk-backed videos count — never orphaned
        // chunks (no videos row), which can't be re-embedded by a disk walk and
        // would otherwise keep the migration offer alive forever.
        let sql = """
            SELECT COUNT(DISTINCT c.video_id), COUNT(*)
            FROM chunks c JOIN videos v ON v.video_id = c.video_id
            WHERE c.model_version <> ?;
            """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, activeModel)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return (Int(sqlite3_column_int64(stmt, 0)), Int(sqlite3_column_int64(stmt, 1)))
        }
        return (0, 0)
    }

    /// True when any text chunk or frame of a real video was embedded by a
    /// model other than `activeModel` — the trigger for the automatic upgrade.
    func needsModelMigration(activeModel: String) throws -> Bool {
        try openIfNeeded()
        let sql = """
            SELECT EXISTS(SELECT 1 FROM chunks c JOIN videos v ON v.video_id = c.video_id
                          WHERE c.model_version <> ?1)
                OR EXISTS(SELECT 1 FROM frames f JOIN videos v ON v.video_id = f.video_id
                          WHERE f.model_version <> ?1);
            """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, activeModel)
        return sqlite3_step(stmt) == SQLITE_ROW && sqlite3_column_int64(stmt, 0) != 0
    }

    /// True when `videoID` has rows in `table` ("chunks" or "frames") and every
    /// one of them was embedded by `model` — i.e. the upgrade can skip it.
    func isCurrent(_ table: String, videoID: String, model: String) throws -> Bool {
        precondition(table == "chunks" || table == "frames")
        try openIfNeeded()
        let stmt = try prepare("SELECT COUNT(*), COALESCE(SUM(model_version <> ?), 0) FROM \(table) WHERE video_id = ?;")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, model)
        bindText(stmt, 2, videoID)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return false }
        return sqlite3_column_int64(stmt, 0) > 0 && sqlite3_column_int64(stmt, 1) == 0
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

    // MARK: - Shared copy for the MCP server

    /// Folder inside the vault that holds the published index copy.
    nonisolated static let snapshotFolder = ".youty"

    /// Publishes the base tables to `{vault}/.youty/index.db` so the MCP server
    /// can search without reading the app's container. Skips the write when the
    /// published copy is already newer than every index change. Only the app's
    /// index is published: the CLI's private fallback index would otherwise
    /// replace the app's fuller copy. Never throws: a failed publish keeps the
    /// previous copy and is retried after the next index change or launch.
    func publishSnapshot(toVault vaultRoot: URL) {
        do {
            // The app's index lives in its container; so does the CLI's when it
            // can read the app's index. Test and probe copies are never published.
            guard databaseURL == nil,
                  try Self.defaultDatabaseURL().path.contains("/Containers/dev.leget.youty/") else { return }
            try writeSnapshot(toVault: vaultRoot)
        } catch {
            NSLog("[youty] couldn't share the search index with AI apps: \(error.localizedDescription)")
        }
    }

    /// Writes the published copy for whichever index this store holds. A save
    /// changes one video, so the last copy is cloned (instant on APFS) and only
    /// the rows that changed are written. The copy is written whole the first
    /// time, when it is in an older format or comes from another index, and
    /// once re-saves have left a quarter of it as free space.
    func writeSnapshot(toVault vaultRoot: URL) throws {
        try openIfNeeded()
        let dbURL = try databaseFileURL()
        let scoped = vaultRoot.startAccessingSecurityScopedResource()
        defer { if scoped { vaultRoot.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        let folder = vaultRoot.appendingPathComponent(Self.snapshotFolder, isDirectory: true)
        let target = folder.appendingPathComponent("index.db")
        let lastChange = [dbURL, URL(fileURLWithPath: dbURL.path + "-wal")]
            .compactMap(Self.modificationDate).max() ?? .distantFuture
        if let published = Self.modificationDate(target), published >= lastChange { return }

        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let partial = folder.appendingPathComponent("index.db.partial")
        try? fm.removeItem(at: partial)
        let cloned = fm.fileExists(atPath: target.path) && (try? fm.copyItem(at: target, to: partial)) != nil
        do {
            if try !(cloned && updateSnapshot(at: partial)) {
                try? fm.removeItem(at: partial)
                try fillSnapshot(at: partial, sql: fullSnapshotSQL())
            }
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
        guard rename(partial.path, target.path) == 0 else {
            let reason = String(cString: strerror(errno))
            try? fm.removeItem(at: partial)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: reason])
        }
    }

    /// Format of the published copy. 1 keys chunks and frames by their ids and
    /// indexes them by video, so a publish can find the changed rows by reading
    /// only ids, never the embeddings.
    nonisolated static let snapshotFormat = 1

    /// Base tables only: the MCP builds its search tables itself. Columns are
    /// taken from the index, so the copy follows any future column.
    private func fullSnapshotSQL() throws -> String {
        func definition(_ table: String, key: String) throws -> String {
            let sql = """
            SELECT group_concat('"' || name || '" ' || type || \
            CASE WHEN name = '\(key)' THEN ' PRIMARY KEY' ELSE '' END, ', ') \
            FROM (SELECT name, type FROM pragma_table_info('\(table)', 'main') ORDER BY cid);
            """
            guard let columns = scalarText(sql), !columns.isEmpty else { throw IndexStoreError.schemaResourceMissing }
            return "CREATE TABLE snapshot.\(table) (\(columns));"
        }
        return """
        BEGIN;
        \(try definition("videos", key: "video_id"))
        \(try definition("chunks", key: "chunk_id"))
        \(try definition("frames", key: "frame_id"))
        \(try definition("index_meta", key: "key"))
        CREATE INDEX snapshot.snapshot_chunks_video ON chunks(video_id);
        CREATE INDEX snapshot.snapshot_frames_video ON frames(video_id);
        INSERT INTO snapshot.videos     SELECT * FROM main.videos;
        INSERT INTO snapshot.chunks     SELECT * FROM main.chunks;
        INSERT INTO snapshot.frames     SELECT * FROM main.frames;
        INSERT INTO snapshot.index_meta SELECT * FROM main.index_meta;
        PRAGMA snapshot.user_version = \(Self.snapshotFormat);
        COMMIT;
        """
    }

    // The indexer never edits a chunk or frame row: re-indexing a video replaces
    // its rows under new ids. So the id sets alone say which rows changed. Each
    // id list is read from a video index, and `+ 0` makes SQLite collect it once
    // instead of looking every id up in the other table, so a publish never
    // reads the embeddings of rows that stayed the same.
    private static let updateSnapshotSQL = """
    BEGIN;
    DELETE FROM snapshot.videos;
    INSERT INTO snapshot.videos SELECT * FROM main.videos;
    DELETE FROM snapshot.chunks WHERE chunk_id IN (SELECT chunk_id FROM snapshot.chunks
        WHERE chunk_id NOT IN (SELECT chunk_id + 0 FROM main.chunks));
    INSERT INTO snapshot.chunks SELECT * FROM main.chunks WHERE chunk_id IN (SELECT chunk_id FROM main.chunks
        WHERE chunk_id NOT IN (SELECT chunk_id + 0 FROM snapshot.chunks));
    DELETE FROM snapshot.frames WHERE frame_id IN (SELECT frame_id FROM snapshot.frames
        WHERE frame_id NOT IN (SELECT frame_id + 0 FROM main.frames));
    INSERT INTO snapshot.frames SELECT * FROM main.frames WHERE frame_id IN (SELECT frame_id FROM main.frames
        WHERE frame_id NOT IN (SELECT frame_id + 0 FROM snapshot.frames));
    DELETE FROM snapshot.index_meta;
    INSERT INTO snapshot.index_meta SELECT * FROM main.index_meta;
    COMMIT;
    """

    /// Runs `sql` against the database at `url`, attached as `snapshot`.
    private func fillSnapshot(at url: URL, sql: String) throws {
        try execBound("ATTACH DATABASE ? AS snapshot;", text: url.path)
        do {
            try exec(sql)
            try exec("DETACH DATABASE snapshot;")
        } catch {
            try? exec("ROLLBACK;")
            try? exec("DETACH DATABASE snapshot;")
            throw error
        }
    }

    /// Brings a clone of the last published copy up to date. False when the
    /// clone can't be updated safely, so the caller writes it whole.
    private func updateSnapshot(at url: URL) throws -> Bool {
        // A damaged copy may refuse to attach at all.
        guard (try? execBound("ATTACH DATABASE ? AS snapshot;", text: url.path)) != nil else { return false }
        let updatable = snapshotIsUpdatable()
        try exec("DETACH DATABASE snapshot;")
        guard updatable else { return false }
        do {
            try fillSnapshot(at: url, sql: Self.updateSnapshotSQL)
            return true
        } catch {
            NSLog("[youty] rewriting the shared search index whole: \(error.localizedDescription)")
            return false
        }
    }

    /// The attached `snapshot` is a copy of this same index, in the current
    /// format, with the same columns, and without much free space.
    private func snapshotIsUpdatable() -> Bool {
        guard scalarText("PRAGMA snapshot.user_version;") == String(Self.snapshotFormat),
              let id = scalarText("SELECT value FROM main.index_meta WHERE key = 'index_id';"),
              scalarText("SELECT value FROM snapshot.index_meta WHERE key = 'index_id';") == id else { return false }
        func columns(_ table: String, _ schema: String) -> String? {
            scalarText("SELECT group_concat(name) FROM (SELECT name FROM pragma_table_info('\(table)', '\(schema)') ORDER BY cid);")
        }
        for table in ["videos", "chunks", "frames", "index_meta"] {
            guard let current = columns(table, "main"), columns(table, "snapshot") == current else { return false }
        }
        guard let free = Int(scalarText("PRAGMA snapshot.freelist_count;") ?? ""),
              let pages = Int(scalarText("PRAGMA snapshot.page_count;") ?? "") else { return false }
        return free * 4 <= pages
    }

    nonisolated private static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Returns the absolute on-disk path of the index DB. Useful for the
    /// headless `--reindex` smoke test and for surfacing the location in
    /// Settings.
    static func databasePath() throws -> String {
        return try defaultDatabaseURL().path
    }

    // MARK: - Path

    private static func defaultDatabaseURL() throws -> URL {
        // Same override the MCP server honours; lets tests and probes work on a
        // copy without touching the real index.
        if let override = ProcessInfo.processInfo.environment["YOUTY_INDEX_DB"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        let appSupport = try FileManager.default.url(for: .applicationSupportDirectory,
                                                      in: .userDomainMask,
                                                      appropriateFor: nil,
                                                      create: true)
        let resolved = appSupport
            .appendingPathComponent("Youty", isDirectory: true)
            .appendingPathComponent("index.db")

        // Sandboxed Mac app: `appSupport` already resolves into the app's
        // container, so `resolved` IS the canonical index.
        if resolved.path.contains("/Containers/dev.leget.youty/") {
            return resolved
        }

        // Non-sandboxed (the `youty` CLI): the canonical index the app
        // writes lives in the app's container. Target it when this process may
        // actually read it, so app + CLI share ONE index. macOS can block the
        // container while still reporting that the file exists, so test with a
        // real open; when blocked, fall back to the CLI's own index.
        let containerDB = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Containers/dev.leget.youty/Data/Library/Application Support/Youty/index.db")
        if let handle = FileHandle(forReadingAtPath: containerDB.path) {
            try? handle.close()
            return containerDB
        }
        return resolved
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
        _ = data.withUnsafeBytes { raw in
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
