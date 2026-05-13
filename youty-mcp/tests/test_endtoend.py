"""End-to-end against the seeded DB, calling tool fns directly (no MCP wire).

These tests bypass Gemini by NOT exercising the network path — `_do_search`
falls back to BM25 when embedding fails, and we assert on the spec shape.
For a live Gemini smoke test, see `tests/smoke_live.py`.
"""

from __future__ import annotations

import os

import pytest


@pytest.fixture(autouse=True)
def _force_no_network(monkeypatch, seeded_db):
    db_path, _ = seeded_db
    monkeypatch.setenv("YOUTY_INDEX_DB", str(db_path))
    # Force the key lookup to a value that the network call will reject — the
    # server should then fall back to BM25-only retrieval per spec.
    monkeypatch.setenv("YOUTY_GEMINI_API_KEY", "invalid-key-for-test-only")
    # Reset lazy singletons so each test gets a fresh state.
    from youty_mcp import server

    server._STATE.close()
    server._STATE.__init__()
    yield
    server._STATE.close()


def test_list_videos_returns_seeded(seeded_db):
    from youty_mcp import server

    out = server.list_videos(limit=10)
    assert out["count"] == 3
    ids = {v["video_id"] for v in out["videos"]}
    assert ids == {"yt:abc123", "ig:DEF456", "tt:789xyz"}
    # Date_saved ordering — all same in the fixture so just confirm shape.
    for v in out["videos"]:
        assert "title" in v and "platform" in v and "tags" in v


def test_list_videos_platform_filter(seeded_db):
    from youty_mcp import server

    out = server.list_videos(platform="youtube")
    assert out["count"] == 1
    assert out["videos"][0]["video_id"] == "yt:abc123"


def test_get_video_attaches_frames(seeded_db):
    from youty_mcp import server

    out = server.get_video("yt:abc123")
    assert out["video_id"] == "yt:abc123"
    assert out["title"].startswith("Best AI")
    assert any("00438000.jpg" in p for p in out["frames"])
    assert out["video_md_path"].endswith("video.md")


def test_get_transcript_reads_md(seeded_db):
    from youty_mcp import server

    out = server.get_transcript("yt:abc123")
    assert "HeyGen" in out["transcript"]
    assert out["frontmatter"]["title"] == "yt:abc123 title"
    assert "ai" in out["frontmatter"].get("tags", [])


def test_search_response_shape(seeded_db):
    from youty_mcp import server

    out = server._do_search("HeyGen")
    # Spec shape.
    assert set(out.keys()) >= {"results", "query", "sub_queries", "total_chunks_searched", "ms"}
    assert out["query"] == "HeyGen"
    assert out["total_chunks_searched"] == 8
    for r in out["results"]:
        assert set(r.keys()) >= {
            "video_id", "title", "platform", "url", "score", "chunk",
            "frames", "video_md_path",
        }
        # 2 chunks per video max.
    counts: dict[str, int] = {}
    for r in out["results"]:
        counts[r["video_id"]] = counts.get(r["video_id"], 0) + 1
    assert all(v <= 2 for v in counts.values())


def test_search_finds_relevant_body_chunk(seeded_db):
    from youty_mcp import server

    out = server._do_search("HeyGen avatar")
    # With BM25 fallback alone, HeyGen-mentioning chunks must surface.
    assert len(out["results"]) >= 1
    top = out["results"][0]
    assert top["video_id"] in {"yt:abc123", "ig:DEF456"}


def test_search_frames_empty(seeded_db):
    """With no rows in `frames`, the tool returns an empty, well-shaped response."""
    from youty_mcp import server

    out = server.search_frames("anything")
    assert out["results"] == []
    # Empty case carries a "note" (no frames indexed yet) — not an "error".
    assert "note" in out
    assert out["total_frames_searched"] == 0


def test_find_similar_seeded(seeded_db):
    from youty_mcp import server

    out = server.find_similar("yt:abc123", k=5)
    # Without aligned-distribution embeddings the ordering isn't meaningful,
    # but the shape must be right.
    assert "results" in out
    assert out["anchor_video_id"] == "yt:abc123"


def test_get_video_not_found(seeded_db):
    from youty_mcp import server

    out = server.get_video("bogus:id")
    assert "error" in out


def test_schema_promotion_idempotent(seeded_db):
    """Re-opening the DB shouldn't duplicate vec_chunks rows."""
    from youty_mcp import db as _db

    db_path, _ = seeded_db
    conn1 = _db.open_db(db_path)
    n1 = conn1.execute("SELECT COUNT(*) AS n FROM vec_chunks").fetchone()["n"]
    conn1.close()
    conn2 = _db.open_db(db_path)
    n2 = conn2.execute("SELECT COUNT(*) AS n FROM vec_chunks").fetchone()["n"]
    conn2.close()
    assert n1 == n2 == 8
