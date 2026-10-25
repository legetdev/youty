"""Unified vault search: transcript, on-screen text, and frames in one ranking.

Every chunk and frame in the index lives in one EmbeddingGemma 2 space, so a
single query vector is compared against both, alongside SQLite FTS5 (BM25) for
exact words. The three candidate lists use different score scales, so each is
normalized against its own distribution (mean ± 3σ, as in distribution-based
score fusion) before the scores are combined into moments, and moments are
grouped into videos.
"""
from __future__ import annotations

import bisect
import re
import sqlite3
import struct
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

from .db import resolve_vault_root

POOL = 100            # candidates per list
FRAME_WEIGHT = 1.5    # see search()
TEXT_TYPES = ("header", "description", "body", "frame_text")
KIND_BY_TYPE = {"body": "said", "frame_text": "shown", "header": "about", "description": "about"}
MODALITIES = {
    None: TEXT_TYPES, "any": TEXT_TYPES, "said": ("body",), "shown": ("frame_text",),
    "visual": (), "about": ("header", "description"),
}


@dataclass
class Moment:
    video_id: str
    kind: str                 # said | shown | about | visual
    score: float
    start_ms: int | None = None
    end_ms: int | None = None
    frame_ms: int | None = None
    text: str | None = None


@dataclass
class VideoHit:
    video_id: str
    score: float
    moments: list[Moment] = field(default_factory=list)


# ─────────────────── candidate lists ───────────────────


def _blob(vector: np.ndarray) -> bytes:
    return struct.pack(f"<{len(vector)}f", *vector.astype(np.float32))


def _eligible(platform: str | None, since_ms: int | None, model: str | None, table: str) -> tuple[str, list]:
    """SQL restricting `table` rows (chunks/frames) to the filters, for IN (…)."""
    alias = table[0]
    clauses, params = [], []
    if model:
        clauses.append(f"{alias}.model_version = ?")
        params.append(model)
    if platform:
        clauses.append("v.platform = ?")
        params.append(platform)
    if since_ms is not None:
        clauses.append("v.date_saved >= ?")
        params.append(since_ms)
    key = "chunk_id" if table == "chunks" else "frame_id"
    where = " AND ".join(clauses) or "1"
    return (f"SELECT {alias}.{key} FROM {table} {alias} JOIN videos v ON v.video_id = {alias}.video_id "
            f"WHERE {where}"), params


def _filters(conn, table: str, platform, since_ms, model) -> tuple[str, list]:
    """Extra vec0 constraints for the filters. Platform is a partition key. A
    list of eligible ids makes vec0 fetch every listed vector one by one (14 s
    for 100K frames), so it is used only when it is needed: for a date filter,
    or while an upgrade leaves rows of another model in the index."""
    sql, params = "", []
    if platform:
        sql, params = " AND platform = ?", [platform]
    mixed = model is not None and conn.execute(
        f"SELECT 1 FROM {table} WHERE model_version != ? LIMIT 1", (model,)).fetchone() is not None
    if since_ms is not None or mixed:
        sub, sub_params = _eligible(None, since_ms, model if mixed else None, table)
        key = "chunk_id" if table == "chunks" else "frame_id"
        sql += f" AND {key} IN ({sub})"
        params += sub_params
    return sql, params


def dense_chunks(conn, vector, *, types, platform=None, since_ms=None, model=None, k=POOL):
    """[(chunk_id, cosine)] nearest chunks of the given types, best first."""
    if not types:
        return []
    extra, params = _filters(conn, "chunks", platform, since_ms, model)
    marks = ",".join("?" * len(types))
    rows = conn.execute(
        f"SELECT chunk_id, distance FROM vec_chunks WHERE embedding MATCH ? AND k = ? "
        f"AND chunk_type IN ({marks}){extra} ORDER BY distance",
        [_blob(vector), k, *types, *params],
    ).fetchall()
    # Unit vectors: cosine = 1 - squared euclidean distance / 2.
    return [(int(r[0]), 1.0 - float(r[1]) ** 2 / 2) for r in rows[:k]]


def dense_frames(conn, vector, *, platform=None, since_ms=None, model=None, k=POOL):
    """[(frame_id, cosine)] nearest frames, best first."""
    extra, params = _filters(conn, "frames", platform, since_ms, model)
    rows = conn.execute(
        f"SELECT frame_id, distance FROM vec_frames WHERE embedding MATCH ? AND k = ?{extra} "
        f"ORDER BY distance",
        [_blob(vector), k, *params],
    ).fetchall()
    return [(int(r[0]), 1.0 - float(r[1]) ** 2 / 2) for r in rows[:k]]


def keyword_chunks(conn, query, *, types, platform=None, since_ms=None, k=POOL):
    """[(chunk_id, relevance)] BM25 matches (higher is better)."""
    terms = _fts_terms(query)
    if not terms or not types:
        return []
    marks = ",".join("?" * len(types))
    sql = (
        "SELECT f.rowid, bm25(chunks_fts) AS score FROM chunks_fts f "
        "JOIN chunks c ON c.chunk_id = f.rowid JOIN videos v ON v.video_id = c.video_id "
        f"WHERE chunks_fts MATCH ? AND c.chunk_type IN ({marks})"
    )
    params: list = [terms, *types]
    if platform:
        sql += " AND v.platform = ?"
        params.append(platform)
    if since_ms is not None:
        sql += " AND v.date_saved >= ?"
        params.append(since_ms)
    sql += " ORDER BY score LIMIT ?"
    params.append(k)
    try:
        rows = conn.execute(sql, params).fetchall()
    except sqlite3.OperationalError:
        return []
    return [(int(r[0]), -float(r[1])) for r in rows]


def _fts_terms(query: str) -> str:
    """FTS5 rejects raw punctuation; OR together quoted word tokens."""
    return " OR ".join(f'"{t}"' for t in re.findall(r"\w+", query, flags=re.UNICODE))


def _normalized(scores: list[tuple[int, float]]) -> dict[int, float]:
    """Map each score to [0, 1] against its list's mean ± 3σ."""
    if not scores:
        return {}
    values = np.array([s for _, s in scores], dtype=np.float64)
    mean, std = values.mean(), values.std()
    if std == 0:
        return {i: 1.0 for i, _ in scores}
    low, high = mean - 3 * std, mean + 3 * std
    return {i: float(np.clip((s - low) / (high - low), 0.0, 1.0)) for i, s in scores}


# ─────────────────── search ───────────────────


def search(
    conn: sqlite3.Connection,
    query: str,
    vector: np.ndarray | None,
    *,
    model: str,
    videos: int = 8,
    moments_per_video: int = 3,
    platform: str | None = None,
    since_ms: int | None = None,
    modality: str | None = None,
) -> list[VideoHit]:
    """Rank videos by their best moments for `query`.

    `vector` is None when the on-device encoder is unavailable; search then
    falls back to keywords alone. Dense candidates are restricted to rows
    embedded with `model`, so an index mid-upgrade never compares across spaces.
    """
    types = MODALITIES.get(modality, TEXT_TYPES)
    dense = dense_chunks(conn, vector, types=types, platform=platform, since_ms=since_ms, model=model) \
        if vector is not None else []
    sparse = keyword_chunks(conn, query, types=types, platform=platform, since_ms=since_ms)
    frames = dense_frames(conn, vector, platform=platform, since_ms=since_ms, model=model) \
        if vector is not None and modality in (None, "any", "visual") else []

    chunk_scores: dict[int, float] = {}
    for normalized in (_normalized(dense), _normalized(sparse)):
        for chunk_id, score in normalized.items():
            chunk_scores[chunk_id] = chunk_scores.get(chunk_id, 0.0) + score
    # Text candidates can earn credit from two lists (meaning + exact words),
    # frames from one; boost frames so a strong visual match competes with a
    # strong spoken one. 1.5 scored best on the owner's 73-question evaluation.
    frame_scores = {fid: FRAME_WEIGHT * s for fid, s in _normalized(frames).items()}

    moments = _chunk_moments(conn, chunk_scores) + _frame_moments(conn, frame_scores)
    by_video: dict[str, list[Moment]] = {}
    for moment in sorted(moments, key=lambda m: m.score, reverse=True):
        kept = by_video.setdefault(moment.video_id, [])
        if len(kept) < moments_per_video and not any(_overlaps(moment, other) for other in kept):
            kept.append(moment)
    hits = [VideoHit(vid, kept[0].score, kept) for vid, kept in by_video.items() if kept]
    hits.sort(key=lambda h: h.score, reverse=True)
    return hits[:videos]


def _chunk_moments(conn, scores: dict[int, float]) -> list[Moment]:
    if not scores:
        return []
    marks = ",".join("?" * len(scores))
    rows = conn.execute(
        f"SELECT chunk_id, video_id, chunk_type, chunk_text, chunk_start_ms, chunk_end_ms "
        f"FROM chunks WHERE chunk_id IN ({marks})",
        list(scores),
    ).fetchall()
    return [
        Moment(r["video_id"], KIND_BY_TYPE.get(r["chunk_type"], "said"), scores[int(r["chunk_id"])],
               start_ms=r["chunk_start_ms"], end_ms=r["chunk_end_ms"], text=r["chunk_text"])
        for r in rows
    ]


def _frame_moments(conn, scores: dict[int, float]) -> list[Moment]:
    if not scores:
        return []
    marks = ",".join("?" * len(scores))
    rows = conn.execute(f"SELECT frame_id, video_id, frame_ms FROM frames WHERE frame_id IN ({marks})",
                        list(scores)).fetchall()
    return [Moment(r["video_id"], "visual", scores[int(r["frame_id"])],
                   start_ms=int(r["frame_ms"]), end_ms=int(r["frame_ms"]), frame_ms=int(r["frame_ms"]))
            for r in rows]


def _overlaps(a: Moment, b: Moment) -> bool:
    """Same kind and largely the same stretch of video (or both untimed)."""
    if a.kind != b.kind:
        return False
    if a.start_ms is None or b.start_ms is None:
        return a.kind == "about"
    if a.kind == "visual":
        return abs(a.start_ms - b.start_ms) < 15_000
    a_end, b_end = a.end_ms or a.start_ms, b.end_ms or b.start_ms
    shared = min(a_end, b_end) - max(a.start_ms, b.start_ms)
    shortest = max(1, min(a_end - a.start_ms, b_end - b.start_ms))
    return shared / shortest > 0.5


# ─────────────────── vault paths ───────────────────


def vault_path(vault: Path | None, relative: str | None) -> Path | None:
    """Resolve an indexed path only when it stays inside the selected vault."""
    if vault is None or not relative:
        return None
    try:
        candidate = (vault / relative).resolve()
        return candidate if candidate.is_relative_to(vault.resolve()) else None
    except (OSError, RuntimeError):
        return None


def list_frame_jpgs(folder: Path) -> list[tuple[int, Path]]:
    """Millisecond-named JPEGs in `folder`, sorted by time. Symlinks are skipped
    so a synced vault can't smuggle an arbitrary file out as a 'frame'."""
    out: list[tuple[int, Path]] = []
    try:
        for entry in folder.iterdir():
            if entry.is_symlink() or not entry.is_file() or entry.suffix.lower() != ".jpg":
                continue
            if entry.stem.isdigit():
                out.append((int(entry.stem), entry))
    except OSError:
        return []
    return sorted(out)


def nearest_frame(frames: list[tuple[int, Path]], target_ms: int) -> tuple[int, Path] | None:
    """The captured frame closest in time to `target_ms`."""
    if not frames:
        return None
    keys = [ms for ms, _ in frames]
    i = bisect.bisect_left(keys, target_ms)
    candidates = frames[max(0, i - 1): i + 1]
    return min(candidates, key=lambda f: abs(f[0] - target_ms))


__all__ = ["Moment", "VideoHit", "search", "vault_path", "list_frame_jpgs", "nearest_frame",
           "resolve_vault_root"]
