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


def _STATE_DEFAULT_DB_HINT() -> str:
    return os.environ.get("YOUTY_INDEX_DB", str(_db.DEFAULT_DB_PATH))


# ─────────────────── tools ───────────────────


mcp = FastMCP("youty")


@mcp.tool()
def search(
    query: str,
    k: int = 15,
    platform: str | None = None,
    since_iso: str | None = None,
) -> dict[str, Any]:
    """Semantic + keyword search over every saved video in the user's vault.

    This is the FIRST tool to reach for whenever the user asks a question
    that could be answered using content from their saved YouTube /
    Instagram / TikTok videos. Use it instead of `find`, `grep`, or
    `Read` over the vault — it understands paraphrases, cross-language
    meaning (German ↔ English), and surfaces ranked chunks with frame
    paths and timestamps.

    Internally runs Gemini-embedding-001 (dense) + SQLite FTS5 (BM25)
    fused via RRF. Compound questions get auto-decomposed into ≤3
    sub-queries via Gemini Flash; you don't need to split them yourself.

    Args:
        query: The user's natural-language question, in any language.
            Conversational phrasing works ("what did Matt Wolfe say about
            HeyGen"). Do NOT pre-translate — the embedder is multilingual.
        k: How many ranked results to return. Default 15 is usually fine;
            raise to 25–30 for broad-coverage research, drop to 5 for a
            quick spot-check.
        platform: Restrict to one source. "youtube" | "instagram" |
            "tiktok". Omit to search everything (default).
        since_iso: ISO-8601 date (e.g. "2026-04-01") — only videos saved
            on/after this date. Useful when the user asks about "recent"
            or current-events topics.

    Returns: `{results: [{video_id, title, channel, platform, url, tags,
    score, chunk: {text, start_ms, end_ms, timestamp_label}, frames: [path,…],
    video_md_path, score}, …], query, sub_queries, total_chunks_searched, ms}`.

    Each result row carries enough context to answer most questions
    directly. Promote to `get_transcript(video_id)` only when a chunk is
    truncated mid-thought. Each result also includes nearest frame JPEG
    paths — read them with the `Read` tool when visual context matters.
    """
    return _do_search(query, k=k, platform=platform, since_iso=since_iso)


@mcp.tool()
def get_transcript(video_id: str) -> dict[str, Any]:
    """Read the full timestamped transcript for one video from the Youty vault.

    Call this AFTER `search` whenever a chunk you got back looks promising
    but is truncated — the snippet is ~400 tokens; the full video.md may be
    50× longer. Pass the `video_id` from `search`'s result row (e.g.
    "yt:dQw4w9WgXcQ", "ig:DEF456", "tt:7234567890123456789").

    Returns the parsed frontmatter (title, channel, url, tags, duration,
    date_saved), the full transcript with `[mm:ss]` timestamps, and the
    absolute path to the video.md file. Reliably resolves the file even if
    the bundle folder has been renamed since indexing.

    Prefer this over reading files yourself — it returns structured
    metadata alongside the text.
    """
    conn = _STATE.conn()
    row = conn.execute(
        "SELECT video_id, title, folder_path, platform FROM videos WHERE video_id = ?",
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
    md_path = _resolve_video_md(
        conn, vault, video_id=video_id, folder_path=row["folder_path"], platform=row["platform"]
    )
    if md_path is None:
        return {
            "error": (
                f"video.md not found for {video_id!r}. The vault folder may have "
                f"been deleted or moved outside the indexed platform subfolder. "
                f"Run `--reindex` from the Mac app to refresh."
            ),
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
    """Get full metadata + frame listing for one saved video.

    Use this when you need the structured frontmatter (channel, url, tags,
    duration, save date) and the list of frame JPEG paths for visual
    inspection — e.g. after `search` returns a promising chunk and you
    want to look at frames yourself. For the transcript text, use
    `get_transcript`.

    Returns `folder_path`, `video_md_path`, every file in the bundle,
    and a `frames[]` list of absolute JPEG paths sorted by timestamp.
    Resolves the bundle even if its folder was renamed.
    """
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
    folder: Path | None = None
    if vault is not None:
        md_path = _resolve_video_md(
            conn, vault, video_id=video_id,
            folder_path=row["folder_path"], platform=row["platform"],
        )
        if md_path is not None:
            folder = md_path.parent
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
    """List every video in the vault, most recently saved first.

    Use this to give the user an overview of what they've collected ("what
    do I have saved", "show me my recent IG saves"), or to filter by a
    specific channel/creator. Does NOT do semantic ranking — for "what's
    relevant to topic X", use `search`.

    Args:
        platform: "youtube" | "instagram" | "tiktok" to filter. Omit for all.
        channel: Exact channel/author match (case-sensitive). Use the value
            exactly as it appears in a previous result's `channel` field.
        limit: Hard cap on rows returned. Default 100, max 1000.

    Returns video_id, title, channel, platform, url, duration_ms,
    date_saved, tags for each row. No transcripts or embeddings.
    """
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
    """Find videos in the vault semantically closest to one the user already has.

    Averages the body-chunk vectors of `video_id` and runs cosine top-k
    against every other video's header chunk. Useful when the user finds
    one video they like and asks "what else have I saved like this?" or
    when you want to expand a research thread without asking another
    question.

    Args:
        video_id: Source video — must already be in the vault (use `search`
            or `list_videos` first if you need to find one).
        k: Number of similar videos to return. Default 10.

    Returns one row per similar video with the same metadata shape as
    `search` results, scored by `1 - cosine_distance` (higher = closer).
    """
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
    """Find video frames in the vault that visually match a text description.

    Uses Apple's MobileCLIP-S2 joint text-image space (the same one the
    indexer embedded the frames with). The query is text — what's visible
    in the frame — and results are JPEG paths plus their parent video.

    Right tool for questions like "find the moment showing a ComfyUI node
    graph", "any frames with a whiteboard diagram", "shots of a snowy
    mountain". WRONG tool for transcript-content queries — use `search`
    instead, which does both transcript dense AND BM25.

    Args:
        query: Plain-English visual description. The text encoder is
            primarily English-trained — German visual queries may degrade.
        k: Frame count to return (max 50). Default 10. Capped at 3 per
            video so one busy video doesn't dominate.
        platform: Restrict to "youtube" | "instagram" | "tiktok".

    Returns `results[*].frame.path` — an absolute JPEG path you can pass
    to the `Read` tool to look at the image directly.
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


def _resolve_video_md(
    conn: sqlite3.Connection,
    vault: Path,
    *,
    video_id: str,
    folder_path: str,
    platform: str | None,
) -> Path | None:
    """Resolve the absolute path to a bundle's video.md, healing stale rows.

    1. Try the literal `vault / folder_path / video.md`.
    2. If missing, scan `vault/{platform}/*/video.md`, parse frontmatter
       lines for `video_id` / `post_id`, return the first match.
    3. On a successful fallback, UPDATE the DB row so the next call is
       direct — self-healing for stale folder_paths.
    Returns None if no match anywhere.
    """
    direct = vault / folder_path / "video.md"
    if direct.exists():
        return direct
    raw_id = video_id.split(":", 1)[1] if ":" in video_id else video_id
    platforms = [platform] if platform else ["youtube", "instagram", "tiktok"]
    for plat in platforms:
        platform_dir = vault / plat
        if not platform_dir.is_dir():
            continue
        try:
            candidates = list(platform_dir.iterdir())
        except OSError:
            continue
        for entry in candidates:
            if not entry.is_dir():
                continue
            md = entry / "video.md"
            if not md.is_file():
                continue
            try:
                head = md.read_text(encoding="utf-8", errors="ignore")[:2000]
            except OSError:
                continue
            if not _frontmatter_id_matches(head, raw_id):
                continue
            new_folder_path = f"{plat}/{entry.name}"
            try:
                conn.execute(
                    "UPDATE videos SET folder_path = ? WHERE video_id = ?",
                    (new_folder_path, video_id),
                )
                conn.commit()
                _log.info(
                    "healed stale folder_path for %s: %r → %r",
                    video_id, folder_path, new_folder_path,
                )
            except sqlite3.Error as exc:
                _log.warning("could not persist healed folder_path: %s", exc)
            return md
    return None


def _frontmatter_id_matches(raw: str, raw_id: str) -> bool:
    """True if raw video.md head contains `video_id: {raw_id}` or `post_id: {raw_id}` in the frontmatter block."""
    if not raw.startswith("---"):
        return False
    end = raw.find("\n---", 3)
    block = raw[: end if end != -1 else len(raw)]
    needle_video = f"video_id: {raw_id}"
    needle_post = f"post_id: {raw_id}"
    return needle_video in block or needle_post in block


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

    ms = {
        "embed": embed_ms,
        "retrieve": retrieve_ms,
        "rerank": 0,
        "total": int((time.perf_counter() - t_total) * 1000),
    }
    _log.info(
        "search query=%r k=%d platform=%r since=%r sub_queries=%d "
        "results=%d total_chunks=%d ms=%s",
        query, k, platform, since_iso,
        len(all_queries[1:]), len(results), total_chunks, ms,
    )
    return {
        "results": results,
        "query": query,
        "sub_queries": all_queries[1:],
        "total_chunks_searched": total_chunks,
        "ms": ms,
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
    import sys
    from logging.handlers import RotatingFileHandler

    level_name = os.environ.get("YOUTY_LOG_LEVEL", "INFO").upper()
    level = getattr(logging, level_name, logging.INFO)
    root = logging.getLogger()
    root.setLevel(level)
    fmt = logging.Formatter("%(asctime)s %(levelname)s %(name)s: %(message)s")

    # stderr handler — visible when the user launches `youty-mcp` directly.
    # Claude Desktop / Code MCP harnesses discard this, hence the file handler.
    stderr_h = logging.StreamHandler(stream=sys.stderr)
    stderr_h.setFormatter(fmt)
    root.addHandler(stderr_h)

    # Persistent rotating log file — survives across MCP harness invocations
    # so query patterns, retrieval errors, and `_resolve_video_md` heals are
    # auditable after the fact. ~/Library/Logs/ is Apple-canonical and
    # readable without sudo. Rotates at 2 MB × 3 backups.
    log_dir = Path(
        os.environ.get("YOUTY_LOG_DIR", "~/Library/Logs/Youty")
    ).expanduser()
    try:
        log_dir.mkdir(parents=True, exist_ok=True)
        file_h = RotatingFileHandler(
            log_dir / "youty-mcp.log",
            maxBytes=2_000_000,
            backupCount=3,
            encoding="utf-8",
        )
        file_h.setFormatter(fmt)
        root.addHandler(file_h)
    except OSError as exc:
        # Don't crash the server if the log dir is unwritable — just stderr.
        _log.warning("could not open log file (continuing stderr-only): %s", exc)

    # httpx logs full URLs at INFO — including ?key=... query params. Silence
    # at WARNING so the Gemini API key never reaches any log handler.
    logging.getLogger("httpx").setLevel(logging.WARNING)
    logging.getLogger("httpcore").setLevel(logging.WARNING)
    _log.info("youty-mcp starting (db=%s, log_dir=%s)", _STATE_DEFAULT_DB_HINT(), log_dir)
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
