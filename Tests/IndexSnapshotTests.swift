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

    func testNeverPublishesATestIndex() async throws {
        try await save("yt:one")
        await store.publishSnapshot(toVault: vault)
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.path))
    }
}
