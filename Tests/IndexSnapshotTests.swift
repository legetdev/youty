import SQLite3
import XCTest
@testable import youty

// The published index copy is what the MCP server searches, so it must hold
// every saved video, carry the index's identity, and only be rewritten when
// the index changed. Uses a throwaway index, never the app's real one.

final class IndexSnapshotTests: XCTestCase {

    private var root: URL!
    private var store: IndexStore!
    private var vault: URL { root.appendingPathComponent("vault") }
    private var snapshot: URL { vault.appendingPathComponent(".youty/index.db") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("youty-snapshot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        store = IndexStore(databaseURL: root.appendingPathComponent("index.db"))
    }

    override func tearDown() async throws {
        await store.close()
        try? FileManager.default.removeItem(at: root)
    }

    private func save(_ id: String) async throws {
        try await store.upsertVideo(IndexVideoRow(
            videoID: id, platform: "youtube", title: "Video \(id)", channel: "Channel",
            url: "https://www.youtube.com/watch?v=\(id)", durationMs: 60_000,
            dateSavedMs: 1_700_000_000_000, folderPath: "youtube/Channel - \(id)", tagsJSON: nil))
        let chunk = Chunk(type: .body, index: 0, text: "what \(id) says", embeddingInput: "what \(id) says",
                          startMs: 0, endMs: 5_000)
        try await store.replaceChunks(videoID: id, rows: [
            IndexChunkRow(chunk: chunk, embedding: Array(repeating: 0.5, count: 768), modelVersion: "test@768"),
        ])
    }

    private func query(_ sql: String) throws -> String? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(snapshot.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw XCTSkip("snapshot did not open")
        }
        defer { sqlite3_close_v2(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: text)
    }

    /// Changes the published copy directly, to tell an updated copy from a rewritten one.
    private func edit(_ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(snapshot.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw XCTSkip("snapshot did not open")
        }
        defer { sqlite3_close_v2(db) }
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, sql)
    }

    private func ids(_ path: String, _ table: String) throws -> [String] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close_v2(db) }
        var stmt: OpaquePointer?
        let key = table == "chunks" ? "chunk_id" : "frame_id"
        guard sqlite3_prepare_v2(db, "SELECT \(key) FROM \(table) ORDER BY \(key)", -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(String(cString: sqlite3_column_text(stmt, 0))) }
        return out
    }

    /// Publishing reads the index's modification time, which needs a moment to move.
    private func change(_ work: () async throws -> Void) async throws {
        try await Task.sleep(for: .milliseconds(20))
        try await work()
    }

    private func modified() throws -> Date? {
        try FileManager.default.attributesOfItem(atPath: snapshot.path)[.modificationDate] as? Date
    }

    func testPublishesEverySavedVideoWithItsIdentity() async throws {
        try await save("yt:one")
        try await save("yt:two")
        try await store.writeSnapshot(toVault: vault)

        XCTAssertEqual(try query("SELECT COUNT(*) FROM videos"), "2")
        XCTAssertEqual(try query("SELECT COUNT(*) FROM chunks"), "2")
        XCTAssertEqual(try query("SELECT length(embedding) FROM chunks LIMIT 1"), "3072")
        XCTAssertEqual(try query("SELECT length(value) FROM index_meta WHERE key = 'index_id'"), "32")
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.path + ".partial"))
    }

    func testRewritesOnlyAfterTheIndexChanged() async throws {
        try await save("yt:one")
        try await store.writeSnapshot(toVault: vault)
        let first = try modified()

        try await store.writeSnapshot(toVault: vault)
        XCTAssertEqual(try modified(), first, "an unchanged index must not rewrite the copy")

        try await Task.sleep(for: .milliseconds(20))
        try await save("yt:two")
        try await store.writeSnapshot(toVault: vault)
        XCTAssertEqual(try query("SELECT COUNT(*) FROM videos"), "2")
    }

    func testASaveUpdatesTheCopyInsteadOfRewritingIt() async throws {
        try await save("yt:one")
        try await store.writeSnapshot(toVault: vault)
        XCTAssertEqual(try query("PRAGMA user_version"), String(IndexStore.snapshotFormat))
        try edit("UPDATE chunks SET chunk_text = 'kept' WHERE video_id = 'yt:one'")

        try await change { try await save("yt:two") }
        try await store.writeSnapshot(toVault: vault)

        XCTAssertEqual(try query("SELECT chunk_text FROM chunks WHERE video_id = 'yt:one'"), "kept",
                       "rows that didn't change must not be copied again")
        XCTAssertEqual(try query("SELECT COUNT(*) FROM videos"), "2")
        XCTAssertEqual(try query("SELECT chunk_text FROM chunks WHERE video_id = 'yt:two'"), "what yt:two says")
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.path + ".partial"))
    }

    func testResavesAndRemovalsReachTheCopy() async throws {
        try await save("yt:one")
        try await save("yt:two")
        try await save("yt:three")
        try await store.writeSnapshot(toVault: vault)

        try await change {
            try await save("yt:one")  // re-indexing mints new row ids
            try await store.deleteVideo(videoID: "yt:two")
        }
        try await store.writeSnapshot(toVault: vault)

        let index = root.appendingPathComponent("index.db").path
        XCTAssertEqual(try ids(snapshot.path, "chunks"), try ids(index, "chunks"))
        XCTAssertEqual(try ids(snapshot.path, "chunks").count, 2)
        XCTAssertEqual(try query("SELECT group_concat(video_id) FROM (SELECT video_id FROM videos ORDER BY video_id)"),
                       "yt:one,yt:three")
    }

    func testACopyInAnOlderFormatIsRewrittenWhole() async throws {
        try await save("yt:one")
        try await store.writeSnapshot(toVault: vault)
        try edit("PRAGMA user_version = 0; UPDATE chunks SET chunk_text = 'stale';")

        try await change { try await save("yt:two") }
        try await store.writeSnapshot(toVault: vault)

        XCTAssertEqual(try query("PRAGMA user_version"), String(IndexStore.snapshotFormat))
        XCTAssertEqual(try query("SELECT COUNT(*) FROM chunks WHERE chunk_text = 'stale'"), "0")
        XCTAssertEqual(try query("SELECT COUNT(*) FROM chunks"), "2")
    }

    func testACopyOfAnotherIndexIsRewrittenWhole() async throws {
        try await save("yt:one")
        try await store.writeSnapshot(toVault: vault)
        try edit("UPDATE index_meta SET value = 'other' WHERE key = 'index_id'; UPDATE chunks SET chunk_text = 'stale';")

        try await change { try await save("yt:two") }
        try await store.writeSnapshot(toVault: vault)

        XCTAssertEqual(try query("SELECT COUNT(*) FROM chunks WHERE chunk_text = 'stale'"), "0")
        XCTAssertEqual(try query("SELECT length(value) FROM index_meta WHERE key = 'index_id'"), "32")
    }

    func testADamagedCopyIsRewrittenWhole() async throws {
        try await save("yt:one")
        try await store.writeSnapshot(toVault: vault)
        try Data("not a database".utf8).write(to: snapshot)

        try await change { try await save("yt:two") }
        try await store.writeSnapshot(toVault: vault)

        XCTAssertEqual(try query("SELECT COUNT(*) FROM chunks"), "2")
    }

    func testNeverPublishesATestIndex() async throws {
        try await save("yt:one")
        await store.publishSnapshot(toVault: vault)
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.path))
    }
}
