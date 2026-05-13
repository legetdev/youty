"""Hybrid retrieval — dense (sqlite-vec) + sparse (FTS5 BM25), fused via RRF.

Public surface: `hybrid_search(...) -> list[FusedHit]` and helpers that turn
those hits into the response shape expected by `server.py`.
"""

from __future__ import annotations

import json
import sqlite3
import struct
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

from .db import resolve_vault_root


# ─────────────────── dataclasses ───────────────────


@dataclass
class FusedHit:
    chunk_id: int
    score: float  # RRF score across all retrievers/queries
    dense_rank: int | None = None
    sparse_rank: int | None = None


@dataclass
class ChunkRow:
    chunk_id: int
    video_id: str
    chunk_type: str
    chunk_text: str
    chunk_start_ms: int | None
    chunk_end_ms: int | None


# ─────────────────── core retrieval ───────────────────


def dense_top_k(
    conn: sqlite3.Connection,
    query_vec: list[float],
    k: int = 50,
    platform: str | None = None,
) -> list[tuple[int, float]]:
    """Cosine top-k via sqlite-vec. Returns [(chunk_id, distance), ...] ascending."""
    blob = struct.pack(f"<{len(query_vec)}f", *query_vec)
    # vec_chunks is partitioned by platform + chunk_type — we always restrict to
    # the three text chunk types so all rows are eligible. Platform is optional.
    where_clauses = [
        "embedding MATCH ?",
        "k = ?",
        "chunk_type IN ('header','description','body')",
    ]
    params: list[object] = [blob, k]
    if platform:
        where_clauses.append("platform = ?")
        params.append(platform)
    sql = (
        "SELECT chunk_id, distance FROM vec_chunks WHERE "
        + " AND ".join(where_clauses)
        + " ORDER BY distance"
    )
    rows = conn.execute(sql, params).fetchall()
    return [(int(r["chunk_id"]), float(r["distance"])) for r in rows]


def dense_top_k_frames(
    conn: sqlite3.Connection,
    query_vec: list[float],
    k: int = 50,
    platform: str | None = None,
) -> list[tuple[int, float]]:
    """Cosine top-k over the `vec_frames` table. Returns [(frame_id, distance), ...]."""
    blob = struct.pack(f"<{len(query_vec)}f", *query_vec)
    where_clauses = ["embedding MATCH ?", "k = ?"]
    params: list[object] = [blob, k]
    if platform:
        where_clauses.append("platform = ?")
        params.append(platform)
    sql = (
        "SELECT frame_id, distance FROM vec_frames WHERE "
        + " AND ".join(where_clauses)
        + " ORDER BY distance"
    )
    rows = conn.execute(sql, params).fetchall()
    return [(int(r["frame_id"]), float(r["distance"])) for r in rows]


def sparse_top_k(
    conn: sqlite3.Connection,
    query: str,
    k: int = 50,
    platform: str | None = None,
) -> list[tuple[int, float]]:
    """BM25 top-k via FTS5. Returns [(chunk_id, bm25), ...] ascending (smaller = better)."""
    safe = _sanitize_fts(query)
    if not safe:
        return []
    if platform:
        sql = (
            "SELECT f.rowid AS chunk_id, bm25(chunks_fts) AS score "
            "FROM chunks_fts f "
            "JOIN chunks c ON c.chunk_id = f.rowid "
            "JOIN videos v ON v.video_id = c.video_id "
            "WHERE chunks_fts MATCH ? AND v.platform = ? "
            "ORDER BY score LIMIT ?"
        )
        params: tuple = (safe, platform, k)
    else:
        sql = (
            "SELECT rowid AS chunk_id, bm25(chunks_fts) AS score "
            "FROM chunks_fts WHERE chunks_fts MATCH ? "
            "ORDER BY score LIMIT ?"
        )
        params = (safe, k)
    try:
        rows = conn.execute(sql, params).fetchall()
    except sqlite3.OperationalError:
        # Bad FTS expression — fall back to empty rather than crash retrieval.
        return []
    return [(int(r["chunk_id"]), float(r["score"])) for r in rows]


def _sanitize_fts(query: str) -> str:
    """FTS5 hates raw punctuation; tokenize to word-like terms joined by OR."""
    import re

    tokens = re.findall(r"\w+", query, flags=re.UNICODE)
    # Quote each token defensively to handle reserved words.
    quoted = [f'"{t}"' for t in tokens if t]
    return " OR ".join(quoted)


def rrf_fuse(
    rankings: list[list[int]],
    k: int = 60,
) -> list[FusedHit]:
    """Reciprocal Rank Fusion over an arbitrary number of ranked lists."""
    scores: dict[int, float] = {}
    dense_first: dict[int, int] = {}
    sparse_first: dict[int, int] = {}
    for ridx, ranking in enumerate(rankings):
        is_dense = ridx % 2 == 0  # alternate dense, sparse per query
        for pos, chunk_id in enumerate(ranking):
            scores[chunk_id] = scores.get(chunk_id, 0.0) + 1.0 / (k + pos + 1)
            if is_dense:
                dense_first.setdefault(chunk_id, pos + 1)
            else:
                sparse_first.setdefault(chunk_id, pos + 1)
    fused = [
        FusedHit(
            chunk_id=cid,
            score=score,
            dense_rank=dense_first.get(cid),
            sparse_rank=sparse_first.get(cid),
        )
        for cid, score in scores.items()
    ]
    fused.sort(key=lambda h: h.score, reverse=True)
    return fused


def dedupe_per_video(
    hits: list[FusedHit],
    conn: sqlite3.Connection,
    max_per_video: int = 2,
) -> list[FusedHit]:
    """Keep at most `max_per_video` hits per video_id (highest score wins)."""
    if not hits:
        return []
    ids_csv = ",".join(str(h.chunk_id) for h in hits)
    rows = conn.execute(
        f"SELECT chunk_id, video_id FROM chunks WHERE chunk_id IN ({ids_csv})"
    ).fetchall()
    chunk_to_video = {int(r["chunk_id"]): r["video_id"] for r in rows}

    seen: dict[str, int] = {}
    kept: list[FusedHit] = []
    for h in hits:
        vid = chunk_to_video.get(h.chunk_id)
        if vid is None:
            continue
        if seen.get(vid, 0) >= max_per_video:
            continue
        seen[vid] = seen.get(vid, 0) + 1
        kept.append(h)
    return kept


# ─────────────────── result assembly ───────────────────


def hydrate_results(
    hits: list[FusedHit],
    conn: sqlite3.Connection,
    vault_root: Path | None,
) -> list[dict]:
    """Turn fused hits into the spec'd response shape (with frame paths attached)."""
    if not hits:
        return []
    ids_csv = ",".join(str(h.chunk_id) for h in hits)
    rows = conn.execute(
        f"""
        SELECT
            c.chunk_id, c.video_id, c.chunk_type, c.chunk_text,
            c.chunk_start_ms, c.chunk_end_ms,
            v.title, v.channel, v.platform, v.url, v.duration_ms, v.folder_path, v.tags_json
        FROM chunks c
        JOIN videos v ON v.video_id = c.video_id
        WHERE c.chunk_id IN ({ids_csv})
        """
    ).fetchall()
    by_id = {int(r["chunk_id"]): r for r in rows}

    results: list[dict] = []
    for h in hits:
        r = by_id.get(h.chunk_id)
        if r is None:
            continue
        folder_abs = (
            (vault_root / r["folder_path"]) if vault_root and r["folder_path"] else None
        )
        tags = _parse_tags(r["tags_json"])
        chunk_obj = {
            "text": r["chunk_text"],
            "start_ms": r["chunk_start_ms"],
            "end_ms": r["chunk_end_ms"],
            "timestamp_label": _ms_to_label(r["chunk_start_ms"]),
            "type": r["chunk_type"],
        }
        results.append(
            {
                "video_id": r["video_id"],
                "title": r["title"],
                "channel": r["channel"],
                "platform": r["platform"],
                "url": r["url"],
                "tags": tags,
                "score": round(h.score, 6),
                "chunk": chunk_obj,
                "frames": _frames_for_chunk(
                    folder=folder_abs,
                    chunk_type=r["chunk_type"],
                    start_ms=r["chunk_start_ms"],
                    end_ms=r["chunk_end_ms"],
                    duration_ms=r["duration_ms"],
                ),
                "video_md_path": (
                    str(folder_abs / "video.md") if folder_abs else None
                ),
            }
        )
    return results


def _parse_tags(blob: str | None) -> list[str]:
    if not blob:
        return []
    try:
        data = json.loads(blob)
    except (json.JSONDecodeError, TypeError):
        return []
    if isinstance(data, list):
        return [str(x) for x in data]
    return []


def _ms_to_label(ms: int | None) -> str | None:
    if ms is None:
        return None
    seconds = ms // 1000
    return f"[{seconds // 60}:{seconds % 60:02d}]"


def _frames_for_chunk(
    *,
    folder: Path | None,
    chunk_type: str,
    start_ms: int | None,
    end_ms: int | None,
    duration_ms: int | None,
) -> list[str]:
    """Return 0/1/2 frame paths per the spec rules."""
    if folder is None or not folder.exists():
        return []
    if chunk_type in ("header", "description"):
        return []
    if start_ms is None:
        return []

    jpgs = _list_frame_jpgs(folder)
    if not jpgs:
        return []

    midpoint = start_ms
    if end_ms is not None and end_ms > start_ms:
        midpoint = (start_ms + end_ms) // 2

    nearest = _nearest_jpg(jpgs, midpoint)
    if nearest is None:
        return []

    short_clip = bool(duration_ms and duration_ms < 30_000)
    if short_clip:
        return [str(nearest)]

    second = _nearest_jpg(jpgs, midpoint + 10_000)
    if second is None or second == nearest:
        return [str(nearest)]
    return [str(nearest), str(second)]


def _list_frame_jpgs(folder: Path) -> list[tuple[int, Path]]:
    """Return all numeric-named .jpgs in the folder, sorted by ms timestamp."""
    out: list[tuple[int, Path]] = []
    try:
        for entry in folder.iterdir():
            if not entry.is_file() or entry.suffix.lower() != ".jpg":
                continue
            stem = entry.stem
            if not stem.isdigit():
                continue
            out.append((int(stem), entry))
    except (PermissionError, OSError):
        return []
    out.sort()
    return out


def _nearest_jpg(jpgs: list[tuple[int, Path]], target_ms: int) -> Path | None:
    """Binary-search nearest .jpg by ms timestamp."""
    if not jpgs:
        return None
    import bisect

    keys = [k for k, _ in jpgs]
    idx = bisect.bisect_left(keys, target_ms)
    candidates: list[tuple[int, Path]] = []
    if idx < len(jpgs):
        candidates.append(jpgs[idx])
    if idx > 0:
        candidates.append(jpgs[idx - 1])
    best = min(candidates, key=lambda kv: abs(kv[0] - target_ms))
    return best[1]


# ─────────────────── orchestration ───────────────────


def hybrid_search(
    conn: sqlite3.Connection,
    *,
    query_vecs: list[list[float]],
    query_texts: list[str],
    top_k: int = 15,
    pool: int = 50,
    platform: str | None = None,
) -> list[FusedHit]:
    """Run hybrid retrieval for one or more (vector, text) query pairs and fuse."""
    rankings: list[list[int]] = []
    for vec, text in zip(query_vecs, query_texts):
        if vec:
            rankings.append([cid for cid, _ in dense_top_k(conn, vec, pool, platform)])
        rankings.append([cid for cid, _ in sparse_top_k(conn, text, pool, platform)])
    fused = rrf_fuse(rankings)
    fused = dedupe_per_video(fused, conn, max_per_video=2)
    return fused[:top_k]


__all__ = [
    "FusedHit",
    "dense_top_k",
    "sparse_top_k",
    "rrf_fuse",
    "dedupe_per_video",
    "hybrid_search",
    "hydrate_results",
    "resolve_vault_root",
]
