"""Retrieval-level tests: BM25, RRF fusion, dedupe-per-video, frame search."""

from __future__ import annotations

import json
import sqlite3
import struct

import numpy as np

from youty_mcp import db as _db
from youty_mcp.retrieval import (
    FusedHit,
    dedupe_per_video,
    dense_top_k_frames,
    rrf_fuse,
    sparse_top_k,
)


def test_sparse_top_k_finds_term(seeded_db):
    db_path, _ = seeded_db
    conn: sqlite3.Connection = _db.open_db(db_path)
    hits = sparse_top_k(conn, "HeyGen", 10)
    assert len(hits) >= 1
    # The body chunk that says "HeyGen" should be present.
    chunk_ids = [cid for cid, _ in hits]
    texts = [
        conn.execute(
            "SELECT chunk_text FROM chunks WHERE chunk_id=?", (cid,)
        ).fetchone()["chunk_text"]
        for cid in chunk_ids
    ]
    assert any("HeyGen" in t for t in texts)


def test_sparse_top_k_platform_filter(seeded_db):
    db_path, _ = seeded_db
    conn = _db.open_db(db_path)
    yt_hits = sparse_top_k(conn, "tools", 10, platform="youtube")
    tt_hits = sparse_top_k(conn, "tools", 10, platform="tiktok")
    for cid, _ in yt_hits:
        row = conn.execute(
            "SELECT v.platform FROM chunks c JOIN videos v ON v.video_id=c.video_id WHERE c.chunk_id=?",
            (cid,),
        ).fetchone()
        assert row["platform"] == "youtube"
    for cid, _ in tt_hits:
        row = conn.execute(
            "SELECT v.platform FROM chunks c JOIN videos v ON v.video_id=c.video_id WHERE c.chunk_id=?",
            (cid,),
        ).fetchone()
        assert row["platform"] == "tiktok"


def test_rrf_fuse_orders_by_combined_rank():
    # Item 9 appears top of both rankings → must rank first overall.
    fused = rrf_fuse([[9, 1, 2, 3], [9, 4, 5, 6]])
    ids = [h.chunk_id for h in fused]
    assert ids[0] == 9
    # Items appearing in only one list should rank below the shared top.
    assert set(ids) == {9, 1, 2, 3, 4, 5, 6}


def test_dedupe_per_video_caps_at_two(seeded_db):
    db_path, _ = seeded_db
    conn = _db.open_db(db_path)
    # Four hits from yt:abc123 (all four chunks) — dedupe should cap at 2.
    rows = conn.execute(
        "SELECT chunk_id FROM chunks WHERE video_id='yt:abc123' ORDER BY chunk_id"
    ).fetchall()
    hits = [FusedHit(chunk_id=int(r["chunk_id"]), score=1.0 - i * 0.1) for i, r in enumerate(rows)]
    kept = dedupe_per_video(hits, conn, max_per_video=2)
    assert len(kept) == 2
    # Top-2 by score wins.
    assert kept[0].score >= kept[1].score


def _frame_vec(seed: int, dim: int = 768) -> bytes:
    """fp32-LE little-endian 768-dim vector (SigLIP-Base width), L2-normalised, fake frame embedding."""
    rng = np.random.default_rng(seed)
    v = rng.standard_normal(dim).astype(np.float32)
    v /= np.linalg.norm(v) or 1.0
    return v.tobytes()


def _seed_frames(conn: sqlite3.Connection) -> None:
    """Insert 4 fake frames into the seeded DB (2 yt, 1 ig, 1 tt)."""
    rows = [
        ("yt:abc123", 10_000, "youtube/Matt Wolfe - Best AI Avatar Tools/00010000.jpg", 1),
        ("yt:abc123", 20_000, "youtube/Matt Wolfe - Best AI Avatar Tools/00020000.jpg", 2),
        ("ig:DEF456", 15_000, "instagram/heygen_official - Demo/00015000.jpg", 3),
        ("tt:789xyz", 12_000, "tiktok/aiwhisperer - Top Tools/00012000.jpg", 4),
    ]
    for vid, ms, path, seed in rows:
        conn.execute(
            """INSERT INTO frames
               (video_id, frame_ms, frame_path, phash, model_version,
                embedding_dim, embedding)
               VALUES (?,?,?,?,?,?,?)""",
            (vid, ms, path, None, "siglip-base-patch16-224@768", 768, _frame_vec(seed)),
        )
    conn.commit()


def test_dense_top_k_frames_finds_seeded(seeded_db):
    """Seeded frames must surface via dense vec_frames search with a near-identical query."""
    db_path, _ = seeded_db
    # Pre-promote DB then insert frames + re-open to trigger backfill.
    conn = _db.open_db(db_path)
    _seed_frames(conn)
    conn.close()
    conn = _db.open_db(db_path)

    # Build a query vec equal to seed=2's vector — should hit it as nearest.
    rng = np.random.default_rng(2)
    v = rng.standard_normal(768).astype(np.float32)
    v /= np.linalg.norm(v) or 1.0
    hits = dense_top_k_frames(conn, v.tolist(), k=5)
    assert len(hits) >= 1
    # The matching frame must be the closest.
    closest_id, _ = hits[0]
    row = conn.execute(
        "SELECT video_id, frame_ms FROM frames WHERE frame_id=?", (closest_id,)
    ).fetchone()
    assert row["video_id"] == "yt:abc123"
    assert row["frame_ms"] == 20_000
    for frame_id, cosine_distance in hits:
        blob = conn.execute("SELECT embedding FROM frames WHERE frame_id=?", (frame_id,)).fetchone()[0]
        expected = 1 - float(np.dot(v, np.frombuffer(blob, dtype=np.float32)))
        assert abs(cosine_distance - expected) < 1e-6


def test_search_frames_via_mocked_encoder(seeded_db, monkeypatch):
    """End-to-end shape test for `search_frames`, mocking the CLIP text encoder."""
    db_path, _ = seeded_db
    conn = _db.open_db(db_path)
    _seed_frames(conn)
    conn.close()

    monkeypatch.setenv("YOUTY_INDEX_DB", str(db_path))
    from youty_mcp import server

    server._STATE.close()
    server._STATE.__init__()

    class _FakeEncoder:
        """Return the known Instagram frame's embedding without model loading."""

        def embed_text(self, text: str) -> list[float]:
            rng = np.random.default_rng(3)
            v = rng.standard_normal(768).astype(np.float32)
            v /= np.linalg.norm(v) or 1.0
            return v.tolist()

    monkeypatch.setattr(server._STATE, "_clip_text", _FakeEncoder())
    out = server._do_search_frames("influencer", k=5)
    assert out["total_frames_searched"] == 4
    assert len(out["results"]) >= 1
    top = out["results"][0]
    assert top["video_id"] == "ig:DEF456"
    assert top["frame"]["frame_ms"] == 15_000
    assert top["frame"]["timestamp_label"] == "[0:15]"
    server._STATE.close()


def test_resave_same_chunk_count_rebuilds_keyword_index(seeded_db):
    """A replacement chunk must remove old terms and index the new transcript."""
    db_path, _ = seeded_db
    conn = _db.open_db(db_path)
    writer = sqlite3.connect(db_path)
    writer.row_factory = sqlite3.Row
    row = writer.execute("SELECT * FROM chunks WHERE chunk_id=4").fetchone()
    writer.execute("DELETE FROM chunks WHERE chunk_id=?", (row["chunk_id"],))
    writer.execute(
        """INSERT INTO chunks (video_id, chunk_type, chunk_index, chunk_text,
           chunk_start_ms, chunk_end_ms, model_version, embedding_dim, embedding)
           VALUES (?,?,?,?,?,?,?,?,?)""",
        (row["video_id"], row["chunk_type"], row["chunk_index"], "replacementterm",
         row["chunk_start_ms"], row["chunk_end_ms"], row["model_version"],
         row["embedding_dim"], row["embedding"]),
    )
    writer.commit()
    writer.close()
    assert _db.sync_index(conn)
    assert sparse_top_k(conn, "replacementterm")
    assert not sparse_top_k(conn, "enterprise")
    assert not _db.sync_index(conn)
    conn.close()


def test_vault_root_refreshes_without_restart(seeded_db, tmp_path):
    """Changing the app's saved vault root takes effect in a running server."""
    db_path, vault = seeded_db
    conn = _db.open_db(db_path)
    assert _db.resolve_vault_root(conn) == vault
    moved = tmp_path / "new-vault"
    moved.mkdir()
    conn.execute("UPDATE index_meta SET value=? WHERE key='vault_root'", (str(moved),))
    conn.commit()
    assert _db.resolve_vault_root(conn) == moved
    conn.close()


def test_dense_filters_apply_before_candidate_limit(seeded_db):
    """A nearer excluded vector cannot consume the only requested hit."""
    from youty_mcp.retrieval import dense_top_k

    db_path, _ = seeded_db
    conn = _db.open_db(db_path)
    nearest = conn.execute("SELECT embedding FROM chunks WHERE chunk_id=1").fetchone()[0]
    query = _db.blob_to_vector(nearest)
    conn.execute("UPDATE chunks SET model_version='legacy' WHERE video_id='yt:abc123'")
    conn.execute("UPDATE videos SET date_saved=2000000000000 WHERE video_id='ig:DEF456'")
    conn.commit()
    by_model = dense_top_k(conn, query, k=1, model_version="embeddinggemma-300m@768")
    assert len(by_model) == 1
    assert conn.execute("SELECT video_id FROM chunks WHERE chunk_id=?", (by_model[0][0],)).fetchone()[0] != "yt:abc123"
    by_date = dense_top_k(conn, query, k=1, since_ms=1900000000000)
    assert len(by_date) == 1
    assert conn.execute("SELECT video_id FROM chunks WHERE chunk_id=?", (by_date[0][0],)).fetchone()[0] == "ig:DEF456"
    conn.close()


def test_sparse_date_filter_applies_before_limit(seeded_db):
    """Recent weaker keyword hits survive when an old stronger match exists."""
    db_path, _ = seeded_db
    conn = _db.open_db(db_path)
    conn.execute("UPDATE videos SET date_saved=2000000000000 WHERE video_id='tt:789xyz'")
    conn.commit()
    hits = sparse_top_k(conn, "tools", k=1, since_ms=1900000000000)
    assert len(hits) == 1
    assert conn.execute("SELECT video_id FROM chunks WHERE chunk_id=?", (hits[0][0],)).fetchone()[0] == "tt:789xyz"
    conn.close()


def test_dense_cosine_distances_cover_identical_orthogonal_opposite(tmp_path):
    """Both dense surfaces expose cosine distance, including negative similarity."""
    from youty_mcp.retrieval import dense_top_k

    conn = _db.open_db(tmp_path / "cosine.db")
    conn.execute("""INSERT INTO videos (video_id, platform, title, url, date_saved,
                 folder_path, indexed_at) VALUES ('yt:test','youtube','Test','https://example.com',0,'youtube/test',0)""")
    query = [1.0] + [0.0] * 767
    vectors = [query, [0.0, 1.0] + [0.0] * 766, [-1.0] + [0.0] * 767]
    for i, vector in enumerate(vectors):
        blob = _db.vector_to_blob(vector)
        conn.execute("""INSERT INTO chunks (video_id, chunk_type, chunk_index, chunk_text,
                     model_version, embedding_dim, embedding) VALUES ('yt:test','body',?,'test','test',768,?)""", (i, blob))
        conn.execute("""INSERT INTO frames (video_id, frame_ms, frame_path, model_version,
                     embedding_dim, embedding) VALUES ('yt:test',?,'frame.jpg','test',768,?)""", (i, blob))
    conn.commit()
    _db.sync_index(conn)
    for retriever in (dense_top_k, dense_top_k_frames):
        distances = [distance for _, distance in retriever(conn, query, k=3)]
        np.testing.assert_allclose(distances, [0.0, 1.0, 2.0], atol=1e-6)
    conn.close()
