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


def _frame_vec(seed: int, dim: int = 512) -> bytes:
    """fp32-LE little-endian 512-dim vector, L2-normalised, used as fake frame embedding."""
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
            (vid, ms, path, None, "mobileclip-s2@512", 512, _frame_vec(seed)),
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
    v = rng.standard_normal(512).astype(np.float32)
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


def test_search_frames_via_mocked_encoder(seeded_db, monkeypatch):
    """End-to-end shape test for `search_frames`, mocking the CLIP text encoder."""
    db_path, _ = seeded_db
    conn = _db.open_db(db_path)
    _seed_frames(conn)
    conn.close()

    monkeypatch.setenv("YOUTY_INDEX_DB", str(db_path))
    monkeypatch.setenv("YOUTY_GEMINI_API_KEY", "invalid-key-for-test-only")
    from youty_mcp import server

    server._STATE.close()
    server._STATE.__init__()

    # Force the clip_text encoder to return seed=3's vector (which matches the IG frame).
    class _FakeEncoder:
        def embed_text(self, text: str) -> list[float]:
            rng = np.random.default_rng(3)
            v = rng.standard_normal(512).astype(np.float32)
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
