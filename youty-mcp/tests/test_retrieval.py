"""Unified retrieval: keyword + meaning over text, frames in the same ranking."""

from __future__ import annotations

from youty_mcp import db as _db
from youty_mcp.query_encoder import MODEL_ID
from youty_mcp.retrieval import Moment, _normalized, _overlaps, search

from .conftest import vector


def _ids(hits):
    return [h.video_id for h in hits]


def test_keyword_only_finds_term(seeded_db):
    conn = _db.open_db(seeded_db[0])
    hits = search(conn, "HeyGen", None, model=MODEL_ID)
    assert "yt:abc123" in _ids(hits)
    assert all(m.kind != "visual" for h in hits for m in h.moments)


def test_platform_and_date_filters(seeded_db):
    conn = _db.open_db(seeded_db[0])
    assert _ids(search(conn, "tools", vector(8), model=MODEL_ID, platform="tiktok")) == ["tt:789xyz"]
    assert search(conn, "tools", vector(8), model=MODEL_ID, since_ms=2_000_000_000_000) == []


def test_meaning_ranks_matching_chunk_first(seeded_db):
    conn = _db.open_db(seeded_db[0])
    hits = search(conn, "influencer platform", vector(6), model=MODEL_ID)
    assert hits[0].video_id == "ig:DEF456"
    assert hits[0].moments[0].kind == "said"


def test_frames_compete_in_the_same_ranking(seeded_db):
    conn = _db.open_db(seeded_db[0])
    hits = search(conn, "zzz", vector(103), model=MODEL_ID)  # no keyword help
    assert hits[0].video_id == "tt:789xyz"
    assert hits[0].moments[0].kind == "visual"
    only_visual = search(conn, "anything", vector(101), model=MODEL_ID, modality="visual")
    assert only_visual[0].video_id == "yt:abc123"
    assert {m.kind for h in only_visual for m in h.moments} == {"visual"}


def test_other_model_vectors_are_never_compared(seeded_db):
    conn = _db.open_db(seeded_db[0])
    conn.execute("UPDATE chunks SET model_version = 'old-model' WHERE video_id = 'ig:DEF456'")
    conn.execute("UPDATE frames SET model_version = 'old-model'")
    conn.commit()
    hits = search(conn, "zzz", vector(6), model=MODEL_ID)
    assert "ig:DEF456" not in _ids(hits)
    assert all(m.kind != "visual" for h in hits for m in h.moments)


def test_normalization_and_overlap_rules():
    assert _normalized([(1, 0.5), (2, 0.5)]) == {1: 1.0, 2: 1.0}
    spread = _normalized([(1, 0.9), (2, 0.1), (3, 0.2)])
    assert spread[1] > spread[3] > spread[2]
    a = Moment("v", "said", 1.0, 0, 60_000)
    assert _overlaps(a, Moment("v", "said", 1.0, 10_000, 70_000))
    assert not _overlaps(a, Moment("v", "said", 1.0, 50_000, 120_000))
    assert not _overlaps(a, Moment("v", "visual", 1.0, 0, 0))
