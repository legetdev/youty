"""Youty MCP server entrypoint.

Exposes seven tools — `search`, `get_transcript`, `get_video`, `view_frames`,
`list_videos`, `find_similar`, `search_frames` — over stdio. Designed to be
wired into Claude Desktop / Claude Code / Cursor via their MCP config files.

The core agentic loop: `search` finds the relevant moments → `get_transcript`
pulls the words into context → `view_frames` loads the matching frames into the
model's vision. `view_frames` returns the JPEGs as native MCP image content, so
the loop's visual half works in EVERY client — not just Claude Code, which is
the only one with a filesystem `Read` tool.

Text search is 100% on-device: queries are embedded with EmbeddingGemma
(`embeddinggemma_text.py`), the same model the indexer embeds documents with.
No API key, no cloud calls. The server holds a single long-lived sqlite3
connection; the query encoder is loaded lazily (and warmed in the background
at startup) on first use.
"""

from __future__ import annotations

import json
import logging
import os
import sqlite3
import struct
import threading
import time
from pathlib import Path
from typing import Any

from mcp.server.fastmcp import FastMCP, Image

from . import db as _db
from .retrieval import (
    dense_top_k,
    dense_top_k_frames,
    hybrid_search,
    hydrate_results,
    resolve_vault_root,
    sparse_top_k,
)


_log = logging.getLogger("youty_mcp")


# Defensive cap on free-form string args coming from the MCP client. 10 KB is
# orders of magnitude above any human-typed query and keeps a misbehaving
# caller from streaming megabytes into the encoder / SQLite. Applied at every
# tool boundary.
_MAX_STRING_ARG = 10_000


# Hard ceiling on how many frames `view_frames` returns as inline images. Each
# image is real vision tokens for the model, so "look at this" stays deliberate
# and cheap — the agent asks for the few frames that matter, not a contact sheet.
_MAX_VIEW_FRAMES = 12


def _clamp(s: str | None) -> str | None:
    """Truncate untrusted string args to a sane upper bound."""
    if s is None:
        return None
    if len(s) <= _MAX_STRING_ARG:
        return s
    return s[:_MAX_STRING_ARG]


# ─────────────────── lazy singletons ───────────────────


class _State:
    """Lazily-instantiated singletons (DB + on-device EmbeddingGemma + SigLIP)."""

    def __init__(self) -> None:
        self._conn: sqlite3.Connection | None = None
        self._clip_text = None  # SigLIPTextEncoder
        self._eg_text = None  # EmbeddingGemmaTextEncoder
        self._eg_lock = threading.Lock()  # guards _eg_text creation
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

    def current_text_model(self) -> str:
        """Which model the index's text chunks were embedded with (index_meta)."""
        try:
            row = self.conn().execute(
                "SELECT value FROM index_meta WHERE key='current_text_model'"
            ).fetchone()
            return (row["value"] if row else "") or ""
        except sqlite3.Error:
            return ""

    def text_embedder(self):
        """The on-device EmbeddingGemma query encoder — the only text embedder.
        Documents are embedded with the same model, so query + document vectors
        share one space. No API key, no cloud call. Loaded lazily, guarded so a
        background warm-up and a concurrent first query can't double-load."""
        if self._eg_text is None:
            with self._eg_lock:
                if self._eg_text is None:
                    from .embeddinggemma_text import EmbeddingGemmaTextEncoder

                    self._eg_text = EmbeddingGemmaTextEncoder()
        return self._eg_text

    def warm_text_embedder(self) -> None:
        """Force-load the on-device EG query encoder so the user's FIRST `search`
        doesn't pay the one-time torch / sentence-transformers import + model
        load (~5-7 s). Touches NO database — the sqlite connection is
        main-thread-only (check_same_thread), so this is safe on the startup
        daemon thread. The torch model loaded here is reused by queries on the
        event-loop thread (PyTorch CPU models carry no thread affinity). Any
        failure is non-fatal — the first query then loads lazily, exactly as
        before."""
        try:
            with self._eg_lock:
                if self._eg_text is None:
                    from .embeddinggemma_text import EmbeddingGemmaTextEncoder

                    self._eg_text = EmbeddingGemmaTextEncoder()
            t0 = time.perf_counter()
            self._eg_text.embed_query("warmup")  # forces import + model load + first inference
            _log.info("EmbeddingGemma query encoder warmed in %.1fs", time.perf_counter() - t0)
        except Exception as exc:  # noqa: BLE001
            _log.warning("text-embedder warm-up failed (first query will load lazily): %s", exc)

    def clip_text(self):
        """Lazy SigLIP-Base text encoder. Raises if transformers/torch missing."""
        if self._clip_text is None:
            from .siglip_text import SigLIPTextEncoder

            self._clip_text = SigLIPTextEncoder()
        return self._clip_text

    def close(self) -> None:
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

    Internally runs a dense embedder + SQLite FTS5 (BM25) fused via RRF.
    The dense side is the on-device EmbeddingGemma model — the same model the
    index was built with, so no API key and no cloud call. Compound questions
    work fine as-is; you don't need to split them yourself.

    Results cover both what a video *said* and what it *showed*: each result's
    `chunk.type` is "body"/"description"/"header" for the spoken transcript +
    metadata, or "frame_text" for text recognized **on-screen** via OCR (slides,
    code, terminal output, labels). A "frame_text" hit means the answer was
    visible in the video — pair it with `view_frames` to see that moment.

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
    directly. The natural next steps: `get_transcript(video_id)` to pull a
    whole video's words into context when a chunk is truncated mid-thought,
    and — when visual context matters — `view_frames(video_id,
    frame_ms=[…])` to actually SEE the nearest frames (pass the result's
    `frames` timestamps or the chunk `start_ms`). `view_frames` returns the
    images themselves, so it works in every client; the raw frame paths are
    in each row too, but only Claude Code can open a path on its own.
    """
    return _do_search(_clamp(query) or "", k=k, platform=platform, since_iso=since_iso)


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
    want the full frame inventory. For the transcript text, use
    `get_transcript`; to actually SEE frames as images, use `view_frames`.

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
# No return annotation on purpose: it returns mixed text + image content, not a
# JSON object. Without an annotation FastMCP emits unstructured content blocks
# (text + images) on every supported mcp version, instead of trying to validate
# the Image objects against an auto-generated output schema.
def view_frames(
    video_id: str,
    frame_ms: list[int] | None = None,
    max_frames: int = 6,
):
    """Load a video's frames into your vision — the "see it" step of the loop.

    This is how you actually LOOK at what's on screen. `search` and
    `search_frames` hand you frame *paths* and timestamps; this tool returns
    the JPEGs themselves as images you can see directly, in ANY MCP client
    (Claude Desktop, Cursor, Claude Code) — no filesystem access needed.

    The loop: `search` finds the relevant moments → `get_transcript` pulls the
    words into context → `view_frames` shows you what was on screen at those
    moments, so you reason over both what was said and what was shown.

    Args:
        video_id: The video to view, e.g. "yt:dQw4w9WgXcQ" — from any
            `search` / `search_frames` / `list_videos` result row.
        frame_ms: Specific moments to see, in milliseconds. Pass the
            `frame.frame_ms` values (or a chunk's `start_ms`) from a prior
            `search` / `search_frames` so you see exactly the frames that
            matter — for each one the closest captured frame is returned.
            Omit to get an even sample across the whole video (a quick
            visual overview).
        max_frames: Cap on how many images to return (default 6, hard max
            12). Each image costs vision tokens — keep it small and targeted.

    Returns a short text header naming each frame's timestamp, followed by the
    frame images themselves, in timestamp order.
    """
    return _do_view_frames(video_id, frame_ms=frame_ms, max_frames=max_frames)


def _do_view_frames(
    video_id: str,
    *,
    frame_ms: list[int] | None = None,
    max_frames: int = 6,
) -> list[Any]:
    """Inner impl, callable from tests without MCP framing.

    Resolves the bundle on disk and returns `[header_text, Image, …]`. Frame
    JPEGs are named by their millisecond offset (8-digit zero-padded), so the
    filename stem IS the timestamp — no DB round-trip needed to pick frames.
    """
    conn = _STATE.conn()
    row = conn.execute(
        "SELECT video_id, title, folder_path, platform FROM videos WHERE video_id = ?",
        (video_id,),
    ).fetchone()
    if row is None:
        return [f"video_id {video_id!r} not found"]

    vault = resolve_vault_root(conn)
    if vault is None:
        return [
            "Vault location unknown — re-save a video from the Mac app to refresh the index."
        ]
    md_path = _resolve_video_md(
        conn, vault, video_id=video_id,
        folder_path=row["folder_path"], platform=row["platform"],
    )
    folder = md_path.parent if md_path is not None else None
    if folder is None or not folder.exists():
        return [f"no bundle folder found on disk for {video_id!r}"]

    # Frame filename stem is the timestamp in ms (8-digit zero-pad), e.g. 00438000.jpg.
    available: list[tuple[int, Path]] = []
    for f in sorted(folder.iterdir()):
        if f.is_file() and f.suffix.lower() == ".jpg" and f.stem.isdigit():
            available.append((int(f.stem), f))
    if not available:
        return [
            f"no frames on disk for {video_id!r} — re-save the video from the Mac app "
            "to extract frames."
        ]

    cap = max(1, min(int(max_frames), _MAX_VIEW_FRAMES))
    if frame_ms:
        # Closest captured frame to each requested ms; de-duplicate, keep order.
        picked: dict[int, Path] = {}
        for want in frame_ms:
            try:
                ms_i = int(want)
            except (TypeError, ValueError):
                continue
            nearest_ms, nearest_path = min(available, key=lambda a: abs(a[0] - ms_i))
            picked[nearest_ms] = nearest_path
            if len(picked) >= cap:
                break
        chosen = sorted(picked.items())[:cap]
    elif len(available) <= cap:
        chosen = available
    else:
        # Even sample across the timeline (first … last inclusive).
        step = (len(available) - 1) / (cap - 1) if cap > 1 else 0
        idxs = sorted({round(i * step) for i in range(cap)})
        chosen = [available[i] for i in idxs]

    header = "{} — {} frame(s): {}".format(
        row["title"] or video_id,
        len(chosen),
        ", ".join(_ms_to_label(ms) for ms, _ in chosen),
    )
    out: list[Any] = [header]
    out.extend(Image(path=str(path)) for _ms, path in chosen)
    return out


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
    channel = _clamp(channel)
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
    _db.sync_index(conn)  # promote any video saved since startup (no restart needed)
    # Confine to the index's current text-embedding space so a mixed-model index
    # (mid-migration) never averages two spaces into a meaningless centroid or
    # compares across spaces — the same guard `search` applies. NULL skips it.
    model = _STATE.current_text_model() or None
    src_sql = (
        "SELECT embedding, embedding_dim FROM chunks "
        "WHERE video_id = ? AND chunk_type = 'body'"
        + (" AND model_version = ?" if model else "")
    )
    src_params: list[object] = [video_id] + ([model] if model else [])
    rows = conn.execute(src_sql, src_params).fetchall()
    if not rows:
        return {
            "results": [],
            "note": f"no body chunks for {video_id!r}",
            "video_id": video_id,
        }

    avg = _average_vectors([r["embedding"] for r in rows], rows[0]["embedding_dim"])
    blob = struct.pack(f"<{len(avg)}f", *avg)
    # Search header chunks of OTHER videos, in the same embedding space.
    sql = (
        "SELECT vc.chunk_id, vc.distance, c.video_id "
        "FROM vec_chunks vc JOIN chunks c ON c.chunk_id = vc.chunk_id "
        "WHERE vc.embedding MATCH ? AND vc.k = ? AND vc.chunk_type = 'header' "
        "AND c.video_id != ?"
        + (" AND c.model_version = ?" if model else "")
        + " ORDER BY vc.distance"
    )
    knn_params: list[object] = [blob, max(k * 3, 20), video_id] + ([model] if model else [])
    try:
        sim_rows = conn.execute(sql, knn_params).fetchall()
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

    Uses Google's SigLIP-Base joint text-image space (the same one the
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

    Returns `results[*].frame.path` (absolute JPEG path) and
    `results[*].frame.frame_ms`. To actually SEE the matches, pass those
    `frame_ms` to `view_frames(video_id, frame_ms=[…])` — it returns the
    images themselves, viewable in any client (not just Claude Code, which
    is the only one that can open a raw path on its own).
    """
    return _do_search_frames(_clamp(query) or "", k=k, platform=platform)


def _do_search_frames(
    query: str, *, k: int = 10, platform: str | None = None
) -> dict[str, Any]:
    """Inner impl, callable from tests without MCP framing."""
    t_total = time.perf_counter()
    conn = _STATE.conn()
    _db.sync_index(conn)  # promote any video saved since startup (no restart needed)

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

    # Embed the query via the local SigLIP-Base text encoder.
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
    # Parameterised IN-list — frame_id is currently always an int from
    # `dense_top_k_frames`, but f-string SQL is the wrong default everywhere.
    frame_ids = [fid for fid, _ in raw]
    placeholders = ",".join("?" * len(frame_ids))
    rows = conn.execute(
        f"""
        SELECT f.frame_id, f.video_id, f.frame_ms, f.frame_path,
               v.title, v.channel, v.platform, v.url, v.duration_ms,
               v.folder_path, v.tags_json
        FROM frames f
        JOIN videos v ON v.video_id = f.video_id
        WHERE f.frame_id IN ({placeholders})
        """,
        frame_ids,
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
    _db.sync_index(conn)  # promote any video saved since startup (no restart needed)

    # Text search is on-device only: one query, embedded with EmbeddingGemma.
    # (There is no cloud query-decomposition step — the dense encoder handles
    # compound questions directly.)
    all_queries: list[str] = [query]

    # Embed the query (dense side). Fail soft — fall back to BM25-only if the
    # on-device encoder can't load (e.g. model not yet downloaded).
    t_embed = time.perf_counter()
    query_vecs: list[list[float]] = []
    try:
        embedder = _STATE.text_embedder()
        try:
            query_vecs.append(embedder.embed_query(query))
        except Exception as exc:  # noqa: BLE001
            _log.warning("embed failed for %r: %s", query, exc)
            query_vecs.append([])  # keep alignment
    except RuntimeError as exc:
        # On-device encoder unavailable — sparse-only retrieval.
        _log.warning("embedder unavailable; falling back to BM25 only: %s", exc)
        query_vecs = [[]]
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
        # Confine the dense side to the index's current text-embedding space so
        # a mixed-model index (mid-migration) never returns garbage cosines.
        model_version=_STATE.current_text_model() or None,
    )

    # Optional since_iso post-filter (lightweight: parse + compare unix ms).
    since_cutoff_ms: int | None = _parse_since(since_iso)
    if since_cutoff_ms is not None and fused:
        placeholders = ",".join("?" * len(fused))
        ds_rows = conn.execute(
            f"""SELECT c.chunk_id, v.date_saved FROM chunks c
                JOIN videos v ON v.video_id = c.video_id
                WHERE c.chunk_id IN ({placeholders})""",
            [h.chunk_id for h in fused],
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
    """Parse ISO-8601 → unix ms (UTC). Returns None on bad input.

    A date-only input (e.g. "2026-04-01") has no timezone; interpret it as UTC
    (not the server's local tz) so the cutoff matches the UTC `videos.date_saved`
    rather than drifting by the local offset at the day boundary."""
    if not since_iso:
        return None
    from datetime import datetime, timezone

    try:
        dt = datetime.fromisoformat(since_iso.replace("Z", "+00:00"))
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
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

    _log.info("youty-mcp starting (db=%s, log_dir=%s)", _STATE_DEFAULT_DB_HINT(), log_dir)
    try:
        # Touch the DB on startup so schema promotion runs before stdio begins.
        _STATE.conn()
    except Exception as exc:  # noqa: BLE001
        _log.error("startup failed: %s", exc)
        raise
    # Warm the on-device query encoder in the background so the user's first
    # `search` is fast (~100 ms) instead of paying the one-time torch import +
    # model load. The index check runs HERE on the main thread (sqlite is
    # main-thread-only) — only warm when the index actually holds on-device text
    # chunks, so an empty/un-indexed DB doesn't load torch for nothing. The
    # daemon thread then loads only the torch model and never touches the DB.
    # Never blocks stdio startup or shutdown; a query arriving mid-warm safely
    # waits on the shared load lock.
    try:
        if _STATE.current_text_model().startswith("embeddinggemma"):
            threading.Thread(target=_STATE.warm_text_embedder,
                             name="eg-warm", daemon=True).start()
    except Exception as exc:  # noqa: BLE001
        _log.warning("could not start embedder warm-up thread: %s", exc)
    try:
        mcp.run()
    finally:
        _STATE.close()


if __name__ == "__main__":
    main()
