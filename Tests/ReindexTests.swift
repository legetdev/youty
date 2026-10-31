import SQLite3
import XCTest
@testable import youty

// A note that changes after it was indexed (a re-save, or an on-device
// transcript upgraded to YouTube's captions) must be re-embedded; an unchanged
// one must not. Uses a throwaway index, never the app's real one.

final class ReindexTests: XCTestCase {

    private struct FakeEmbedder: Embedder {
        let modelIdentifier = "test@768"
        let embeddingDim = 768
        func embed(_ texts: [String]) async throws -> [[Float]] {
            texts.map { _ in Array(repeating: 0.5, count: 768) }
        }
    }

    private var root: URL!
    private var store: IndexStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("youty-reindex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("vault/youtube/Ali - Video"),
                                                withIntermediateDirectories: true)
        store = IndexStore(databaseURL: root.appendingPathComponent("index.db"))
    }

    override func tearDown() async throws {
        await store.close()
        try? FileManager.default.removeItem(at: root)
    }

    private func note(_ transcript: String) -> String {
        """
        ---
        title: "Video"
        platform: youtube
        video_id: C0jOKDJtK9s
        url: https://www.youtube.com/watch?v=C0jOKDJtK9s
        channel: "Ali Abdaal"
        duration: "46:33"
        date_saved: 2026-10-31T17:19:46Z
        tags: []
        ---

        ## Transcript

        \(transcript)

        """
    }

    private func bodyText() throws -> String {
        var db: OpaquePointer?
        guard sqlite3_open_v2(root.appendingPathComponent("index.db").path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK
        else { throw XCTSkip("index did not open") }
        defer { sqlite3_close_v2(db) }
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT group_concat(chunk_text, ' ') FROM chunks WHERE chunk_type = 'body'", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) else { return "" }
        return String(cString: text)
    }

    func testAnEditedNoteIsReembeddedAndAnUnchangedOneIsNot() async throws {
        let vault = root.appendingPathComponent("vault")
        let file = vault.appendingPathComponent("youtube/Ali - Video/video.md")
        try note("[4:16.440] AI, yong, sang, sang, sang.").write(to: file, atomically: true, encoding: .utf8)
        let first = try await Indexer.indexBundle(videoMdURL: file, vaultRoot: vault, embedder: FakeEmbedder(), store: store)
        XCTAssertGreaterThan(first, 0)
        let unchanged = try await Indexer.indexBundle(videoMdURL: file, vaultRoot: vault, embedder: FakeEmbedder(), store: store)
        XCTAssertEqual(unchanged, 0)

        // Edited after it was indexed, and re-indexed later, as in real use.
        try await Task.sleep(for: .milliseconds(50))
        try note("[0:00] Oh my god, Opus is incredible at making launch videos.").write(to: file, atomically: true, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(50))
        // Frame indexing refreshes the video's details first; that alone must
        // not make the edited transcript look indexed.
        try await store.upsertVideo(IndexVideoRow(
            videoID: "yt:C0jOKDJtK9s", platform: "youtube", title: "Video", channel: "Ali Abdaal",
            url: "https://www.youtube.com/watch?v=C0jOKDJtK9s", durationMs: 2_793_000,
            dateSavedMs: 1_793_467_186_000, folderPath: "youtube/Ali - Video", tagsJSON: nil))
        let looksIndexed = await Indexer.isIndexed(file, videoID: "yt:C0jOKDJtK9s", store: store)
        XCTAssertFalse(looksIndexed, "the launch check must still see the edited note as pending")
        let edited = try await Indexer.indexBundle(videoMdURL: file, vaultRoot: vault, embedder: FakeEmbedder(), store: store)
        XCTAssertGreaterThan(edited, 0)
        let text = try bodyText()
        XCTAssertTrue(text.contains("Opus is incredible"))
        XCTAssertFalse(text.contains("yong"))
    }
}
