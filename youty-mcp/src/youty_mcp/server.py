"""Youty MCP server entrypoint.

Exposes six tools — `search`, `get_transcript`, `get_video`, `list_videos`,
`find_similar`, `search_frames` — over stdio. Designed to be wired into
Claude Desktop / Claude Code / Cursor via their MCP config files.

The server holds a single long-lived sqlite3 connection and a single httpx
client (wrapped in GeminiEmbedder). Both are created lazily on first use
so smoke tests against an empty DB don't require a network key.
"""

from __future__ import annotations

import json
import logging
import os
import sqlite3
import struct
import time
from pathlib import Path
from typing import Any

from mcp.server.fastmcp import FastMCP

from . import db as _db
from .embedder import GeminiEmbedder, looks_compound
from .keychain import get_gemini_api_key
from .retrieval import (
    dense_top_k,
    dense_top_k_frames,
    hybrid_search,
    hydrate_results,
    resolve_vault_root,
    sparse_top_k,
)


_log = logging.getLogger("youty_mcp")


# ─────────────────── lazy singletons ───────────────────


class _State:
    """Lazily-instantiated singletons (DB + Gemini + MobileCLIP text encoder)."""

    def __init__(self) -> None:
        self._conn: sqlite3.Connection | None = None
        self._embedder: GeminiEmbedder | None = None
        self._clip_text = None  # MobileCLIPTextEncoder
        self._db_path: Path | None = None

    def conn(self) -> sqlite3.Connection:
        if self._conn is None:
            self._db_path = Path(
                os.environ.get("YOUTY_INDEX_DB", str(_db.DEFAULT_DB_PATH))
            ).expanduser()
            self._conn = _db.open_db(self._db_path)
            # Eager-resolve vault root once so retrieval doesn't pay for the scan.
            try:
                _db.resolve_vault_root(self._conn)
            except Exception as exc:  # noqa: BLE001
                _log.warning("vault-root probe failed (non-fatal): %s", exc)
        return self._conn

    def embedder(self) -> GeminiEmbedder:
        if self._embedder is None:
            self._embedder = GeminiEmbedder(get_gemini_api_key())
        return self._embedder

    def clip_text(self):
        """Lazy MobileCLIP-S2 text encoder. Raises if coremltools is missing."""
        if self._clip_text is None:
            from .coreml_text import MobileCLIPTextEncoder

            self._clip_text = MobileCLIPTextEncoder()
        return self._clip_text

    def close(self) -> None:
        if self._embedder is not None:
            self._embedder.close()
        if self._conn is not None:
            self._conn.close()


_STATE = _State()


# ─────────────────── tools ───────────────────


mcp = FastMCP("youty")


@mcp.tool()
def search(
    query: str,
    k: int = 15,
    platform: str | None = None,
    since_iso: str | None = None,
) -> dict[str, Any]:
    """Hybrid semantic + BM25 search over the Youty vault.

    Args:
        query: Free-text user query.
        k: Number of results to return (default 15).
        platform: Optional filter — one of "youtube" | "instagram" | "tiktok".
        since_iso: Optional ISO-8601 date — exclude videos saved before this.

    Returns the spec'd response shape with results, sub_queries, and ms timings.
    """
    return _do_search(query, k=k, platform=platform, since_iso=since_iso)


@mcp.tool()
def get_transcript(video_id: str) -> dict[str, Any]:
    """Read the full `video.md` for a given video. Returns frontmatter + transcript."""
    conn = _STATE.conn()
    row = conn.execute(
        "SELECT video_id, title, folder_path FROM videos WHERE video_id = ?",
        (video_id,),
    ).fetchone()
    if row is None:
        return {"error": f"video_id {video_id!r} not found", "video_id": video_id}

    vault = resolve_vault_root(conn)
    if vault is None:
        return {
            "error": (
                "Vault location unknown — please re-save a video from the Mac app "
                "to refresh the index."
            ),
            "video_id": video_id,
        }
    md_path = vault / row["folder_path"] / "video.md"
    if not md_path.exists():
        return {
            "error": f"video.md missing at {md_path}",
            "video_id": video_id,
        }
    raw = md_path.read_text(encoding="utf-8")
    frontmatter, transcript = _split_video_md(raw)
    return {
        "video_id": video_id,
        "title": row["title"],
        "frontmatter": frontmatter,
        "transcript": transcript,
        "video_md_path": str(md_path),
    }


@mcp.tool()
def get_video(video_id: str) -> dict[str, Any]:
    """Return frontmatter + folder listing + frame paths for a single video."""
    conn = _STATE.conn()
    row = conn.execute(
        """
        SELECT video_id, title, channel, platform, url, duration_ms,
               date_saved, folder_path, tags_json
        FROM videos WHERE video_id = ?
        """,
        (video_id,),
    ).fetchone()
    if row is None:
        return {"error": f"video_id {video_id!r} not found", "video_id": video_id}

    vault = resolve_vault_root(conn)
    folder = (vault / row["folder_path"]) if vault else None
    files: list[str] = []
    frames: list[str] = []
    if folder is not None and folder.exists():
        for f in sorted(folder.iterdir()):
            if not f.is_file():
                continue
            files.append(f.name)
            if f.suffix.lower() == ".jpg" and f.stem.isdigit():
                frames.append(str(f))

    return {
        "video_id": row["video_id"],
        "title": row["title"],
        "channel": row["channel"],
        "platform": row["platform"],
        "url": row["url"],
        "duration_ms": row["duration_ms"],
        "date_saved": row["date_saved"],
        "tags": _safe_load_list(row["tags_json"]),
        "folder_path": str(folder) if folder else None,
        "video_md_path": str(folder / "video.md") if folder else None,
        "files": files,
        "frames": frames,
    }


@mcp.tool()
def list_videos(
    platform: str | None = None,
    channel: str | None = None,
    limit: int = 100,
) -> dict[str, Any]:
    """List videos in the vault, newest first. Optional platform/channel filters."""
    conn = _STATE.conn()
    where: list[str] = []
    params: list[object] = []
    if platform:
        where.append("platform = ?")
        params.append(platform)
    if channel:
        where.append("channel = ?")
        params.append(channel)
    sql = "SELECT video_id, title, channel, platform, url, duration_ms, date_saved, tags_json FROM videos"
    if where:
        sql += " WHERE " + " AND ".join(where)
    sql += " ORDER BY date_saved DESC LIMIT ?"
    params.append(max(1, min(int(limit), 1000)))
    rows = conn.execute(sql, params).fetchall()
    return {
        "videos": [
            {
                "video_id": r["video_id"],
                "title": r["title"],
                "channel": r["channel"],
                "platform": r["platform"],
                "url": r["url"],
                "duration_ms": r["duration_ms"],
                "date_saved": r["date_saved"],
                "tags": _safe_load_list(r["tags_json"]),
            }
            for r in rows
        ],
        "count": len(rows),
    }


@mcp.tool()
def find_similar(video_id: str, k: int = 10) -> dict[str, Any]:
    """Find videos similar to the given one (avg of body-chunk vectors → cosine top-k)."""
    conn = _STATE.conn()
    rows = conn.execute(
        """
        SELECT embedding, embedding_dim FROM chunks
        WHERE video_id = ? AND chunk_type = 'body'
        """,
        (video_id,),
    ).fetchall()
    if not rows:
        return {
            "results": [],
            "note": f"no body chunks for {video_id!r}",
            "video_id": video_id,
        }

    avg = _average_vectors([r["embedding"] for r in rows], rows[0]["embedding_dim"])
    blob = struct.pack(f"<{len(avg)}f", *avg)
    # Search header chunks of OTHER videos.
    sql = """
        SELECT vc.chunk_id, vc.distance, c.video_id
        FROM vec_chunks vc
        JOIN chunks c ON c.chunk_id = vc.chunk_id
        WHERE vc.embedding MATCH ?
          AND vc.k = ?
          AND vc.chunk_type = 'header'
          AND c.video_id != ?
        ORDER BY vc.distance
    """
    try:
        sim_rows = conn.execute(sql, (blob, max(k * 3, 20), video_id)).fetchall()
    except sqlite3.OperationalError:
        sim_rows = []

    # Dedupe by video, hydrate.
    seen: set[str] = set()
    out: list[dict[str, Any]] = []
    for r in sim_rows:
        vid = r["video_id"]
        if vid in seen:
            continue
        seen.add(vid)
        info = conn.execute(
            """
            SELECT video_id, title, channel, platform, url, tags_json
            FROM videos WHERE video_id = ?
            """,
            (vid,),
        ).fetchone()
        if info is None:
            continue
        out.append(
            {
                "video_id": info["video_id"],
                "title": info["title"],
                "channel": info["channel"],
                "platform": info["platform"],
                "url": info["url"],
                "tags": _safe_load_list(info["tags_json"]),
                "score": round(1.0 - float(r["distance"]), 6),
            }
        )
        if len(out) >= k:
            break
    return {"results": out, "anchor_video_id": video_id}


@mcp.tool()
def search_frames(
    query: str,
    k: int = 10,
    platform: str | None = None,
) -> dict[str, Any]:
    """Cross-modal visual search: text → frame embeddings via MobileCLIP-S2.

    Args:
        query: Natural-language description (e.g. "person holding a phone").
        k: Number of frames to return (default 10, max 50).
        platform: Optional "youtube" | "instagram" | "tiktok" filter.

    Returns a result list with `frame_path`, the parent video metadata, and
    the frame timestamp. Up to 3 frames per video.
    """
    return _do_search_frames(query, k=k, platform=platform)


def _do_search_frames(
    query: str, *, k: int = 10, platform: str | None = None
) -> dict[str, Any]:
    """Inner impl, callable from tests without MCP framing."""
    t_total = time.perf_counter()
    conn = _STATE.conn()

    n_frames = int(
        conn.execute("SELECT COUNT(*) AS n FROM frames").fetchone()["n"]
    )
    if n_frames == 0:
        return {
            "results": [],
            "query": query,
            "total_frames_searched": 0,
            "note": "no frames in index — run `--index-frames` from the Mac app first.",
            "ms": {"embed": 0, "retrieve": 0, "total": 0},
        }

    # Embed the query via the local MobileCLIP-S2 text encoder.
    t_embed = time.perf_counter()
    try:
        query_vec = _STATE.clip_text().embed_text(query)
    except Exception as exc:  # noqa: BLE001
        _log.warning("frame query embed failed: %s", exc)
        return {
            "results": [],
            "query": query,
            "total_frames_searched": n_frames,
            "error": f"frame embed failed: {exc}",
            "ms": {"embed": 0, "retrieve": 0, "total": 0},
        }
    embed_ms = int((time.perf_counter() - t_embed) * 1000)

    # Dense top-k against vec_frames, generously oversampled so per-video
    # dedupe still leaves at least k results.
    t_retrieve = time.perf_counter()
    pool = max(k * 5, 30)
    raw = dense_top_k_frames(conn, query_vec, k=pool, platform=platform)
    if not raw:
        return {
            "results": [],
            "query": query,
            "total_frames_searched": n_frames,
            "note": "no frame matches.",
            "ms": {
                "embed": embed_ms,
                "retrieve": int((time.perf_counter() - t_retrieve) * 1000),
                "total": int((time.perf_counter() - t_total) * 1000),
            },
        }

    # Hydrate + dedupe per video (max 3 per video).
    ids_csv = ",".join(str(fid) for fid, _ in raw)
    rows = conn.execute(
        f"""
        SELECT f.frame_id, f.video_id, f.frame_ms, f.frame_path,
               v.title, v.channel, v.platform, v.url, v.duration_ms,
               v.folder_path, v.tags_json
        FROM frames f
        JOIN videos v ON v.video_id = f.video_id
        WHERE f.frame_id IN ({ids_csv})
        """
    ).fetchall()
    by_id = {int(r["frame_id"]): r for r in rows}

    vault = resolve_vault_root(conn)
    per_video: dict[str, int] = {}
    results: list[dict[str, Any]] = []
    for fid, dist in raw:
        r = by_id.get(fid)
        if r is None:
            continue
        vid = r["video_id"]
        if per_video.get(vid, 0) >= 3:
            continue
        per_video[vid] = per_video.get(vid, 0) + 1
        folder_abs = (vault / r["folder_path"]) if vault else None
        frame_abs = (vault / r["frame_path"]) if vault else None
        tags = _safe_load_list(r["tags_json"])
        results.append(
            {
                "video_id": vid,
                "title": r["title"],
                "channel": r["channel"],
                "platform": r["platform"],
                "url": r["url"],
                "duration_ms": r["duration_ms"],
                "tags": tags,
                "score": round(1.0 - float(dist), 6),
                "frame": {
                    "path": str(frame_abs) if frame_abs else r["frame_path"],
                    "frame_ms": int(r["frame_ms"]),
                    "timestamp_label": _ms_to_label(int(r["frame_ms"])),
                },
                "video_md_path": (
                    str(folder_abs / "video.md") if folder_abs else None
                ),
            }
        )
        if len(results) >= k:
            break
    retrieve_ms = int((time.perf_counter() - t_retrieve) * 1000)

    return {
        "results": results,
        "query": query,
        "total_frames_searched": n_frames,
        "ms": {
            "embed": embed_ms,
            "retrieve": retrieve_ms,
            "total": int((time.perf_counter() - t_total) * 1000),
        },
    }


def _ms_to_label(ms: int) -> str:
    seconds = ms // 1000
    return f"[{seconds // 60}:{seconds % 60:02d}]"


# ─────────────────── core search impl ───────────────────


def _do_search(
    query: str,
    *,
    k: int = 15,
    platform: str | None = None,
    since_iso: str | None = None,
) -> dict[str, Any]:
    """Inner implementation, callable from tests without MCP framing."""
    t_total = time.perf_counter()
    conn = _STATE.conn()

    # Multi-query decomposition (best-effort, <=1.5 s, falls back silently).
    sub_queries: list[str] = []
    if looks_compound(query):
        try:
            sub_queries = _STATE.embedder().decompose(query)
        except Exception as exc:  # noqa: BLE001 — silent fallback per spec
            _log.info("multi-query decompose failed, falling back: %s", exc)
            sub_queries = []

    # Always include the original query first; cap total queries at 4.
    all_queries: list[str] = [query]
    for sq in sub_queries:
        if sq.strip() and sq.strip().lower() != query.strip().lower():
            all_queries.append(sq.strip())
        if len(all_queries) >= 4:
            break

    # Embed each query (dense side). Fail soft per query.
    t_embed = time.perf_counter()
    query_vecs: list[list[float]] = []
    try:
        embedder = _STATE.embedder()
        for q in all_queries:
            try:
                query_vecs.append(embedder.embed_query(q))
            except Exception as exc:  # noqa: BLE001
                _log.warning("embed failed for %r: %s", q, exc)
                query_vecs.append([])  # keep alignment
    except RuntimeError as exc:
        # No API key or keychain issue — sparse-only retrieval.
        _log.warning("embedder unavailable; falling back to BM25 only: %s", exc)
        query_vecs = [[] for _ in all_queries]
    embed_ms = int((time.perf_counter() - t_embed) * 1000)

    # Hybrid retrieval.
    t_retrieve = time.perf_counter()
    fused = hybrid_search(
        conn,
        query_vecs=query_vecs,
        query_texts=all_queries,
        top_k=max(1, min(int(k), 50)),
        pool=50,
        platform=platform,
    )

    # Optional since_iso post-filter (lightweight: parse + compare unix ms).
    since_cutoff_ms: int | None = _parse_since(since_iso)
    if since_cutoff_ms is not None and fused:
        ids_csv = ",".join(str(h.chunk_id) for h in fused)
        ds_rows = conn.execute(
            f"""SELECT c.chunk_id, v.date_saved FROM chunks c
                JOIN videos v ON v.video_id = c.video_id
                WHERE c.chunk_id IN ({ids_csv})"""
        ).fetchall()
        keep = {
            int(r["chunk_id"])
            for r in ds_rows
            if r["date_saved"] is not None and int(r["date_saved"]) >= since_cutoff_ms
        }
        fused = [h for h in fused if h.chunk_id in keep]

    vault = resolve_vault_root(conn)
    results = hydrate_results(fused, conn, vault)
    retrieve_ms = int((time.perf_counter() - t_retrieve) * 1000)

    total_chunks = int(
        conn.execute("SELECT COUNT(*) AS n FROM chunks").fetchone()["n"]
    )

    return {
        "results": results,
        "query": query,
        "sub_queries": all_queries[1:],
        "total_chunks_searched": total_chunks,
        "ms": {
            "embed": embed_ms,
            "retrieve": retrieve_ms,
            "rerank": 0,
            "total": int((time.perf_counter() - t_total) * 1000),
        },
    }


# ─────────────────── helpers ───────────────────


def _split_video_md(raw: str) -> tuple[dict[str, Any], str]:
    """Split a YAML frontmatter video.md into (frontmatter_dict, body)."""
    if not raw.startswith("---"):
        return {}, raw
    end_marker = raw.find("\n---", 3)
    if end_marker == -1:
        return {}, raw
    yaml_block = raw[3:end_marker].strip()
    body = raw[end_marker + 4 :].lstrip("\n")
    fm: dict[str, Any] = {}
    # Minimal YAML parser — handles `key: value` and `key:\n  - item` lists.
    current_list_key: str | None = None
    for line in yaml_block.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if line.startswith("  - ") and current_list_key:
            fm.setdefault(current_list_key, []).append(line[4:].strip().strip('"\''))
            continue
        if ":" not in line:
            current_list_key = None
            continue
        key, _, val = line.partition(":")
        key = key.strip()
        val = val.strip()
        if not val:
            current_list_key = key
            fm.setdefault(key, [])
        else:
            current_list_key = None
            fm[key] = val.strip('"\'')
    return fm, body


def _safe_load_list(blob: str | None) -> list[str]:
    if not blob:
        return []
    try:
        data = json.loads(blob)
    except (json.JSONDecodeError, TypeError):
        return []
    return [str(x) for x in data] if isinstance(data, list) else []


def _average_vectors(blobs: list[bytes], dim: int) -> list[float]:
    """Average a list of fp32-little-endian vector blobs into a single fp32 list."""
    import numpy as np

    if not blobs:
        return [0.0] * dim
    mats = [np.frombuffer(b, dtype=np.float32) for b in blobs if len(b) == dim * 4]
    if not mats:
        return [0.0] * dim
    avg = np.mean(np.stack(mats, axis=0), axis=0)
    # L2-normalize so the resulting "synthetic header" vector lives on the unit sphere.
    norm = float(np.linalg.norm(avg))
    if norm > 0:
        avg = avg / norm
    return avg.astype(np.float32).tolist()


def _parse_since(since_iso: str | None) -> int | None:
    """Parse ISO-8601 → unix ms. Returns None on bad input."""
    if not since_iso:
        return None
    from datetime import datetime

    try:
        dt = datetime.fromisoformat(since_iso.replace("Z", "+00:00"))
    except ValueError:
        return None
    return int(dt.timestamp() * 1000)


# ─────────────────── entrypoint ───────────────────


def main() -> None:
    """stdio entrypoint registered as the `youty-mcp` console script."""
    logging.basicConfig(
        level=os.environ.get("YOUTY_LOG_LEVEL", "INFO"),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
        # MCP stdio uses stdout for protocol traffic — log to stderr.
        stream=__import__("sys").stderr,
    )
    # httpx logs full URLs at INFO — including ?key=... query params. Silence
    # at WARNING so the Gemini API key never reaches stderr by accident.
    logging.getLogger("httpx").setLevel(logging.WARNING)
    logging.getLogger("httpcore").setLevel(logging.WARNING)
    try:
        # Touch the DB on startup so schema promotion runs before stdio begins.
        _STATE.conn()
    except Exception as exc:  # noqa: BLE001
        _log.error("startup failed: %s", exc)
        raise
    try:
        mcp.run()
    finally:
        _STATE.close()


if __name__ == "__main__":
    main()
