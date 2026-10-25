"""SQLite connection + schema promotion.

The Swift indexer writes only the four base tables (videos, chunks, frames,
index_meta). At startup the MCP server idempotently promotes the data into
the vec0 virtual table `vec_chunks` and the FTS5 virtual table `chunks_fts`
so dense + sparse retrieval work without any Swift-side work.
"""

from __future__ import annotations

import json
import os
import sqlite3
import struct
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

import sqlite_vec


class IndexUnavailable(RuntimeError):
    """The index can't be reached. The message is plain language for the user."""


# Every message ends in an action the user can take; the server stays up and
# picks the index up on the next tool call once it is reachable.
BLOCKED = (
    "Youty's search index is there, but macOS doesn't let this AI app read it. "
    "Update the Youty app to the latest version and open it once: it then shares "
    "its index in your vault folder, which needs no extra permission."
)
NOT_FOUND = (
    "No Youty library was found on this Mac. Install Youty (youtyapp.vercel.app), "
    "pick a vault folder, and save a video; it becomes searchable here right away."
)

SNAPSHOT = Path(".youty") / "index.db"   # the app's published copy, inside the vault
_DISCOVERY_RETRY_S = 30.0


def _container_db() -> Path:
    return Path("~/Library/Containers/dev.leget.youty/Data/Library/"
                "Application Support/Youty/index.db").expanduser()


def _plain_db() -> Path:
    return Path("~/Library/Application Support/Youty/index.db").expanduser()


def working_db() -> Path:
    """The server's own searchable copy of a published index."""
    return Path(os.environ.get("YOUTY_CACHE_DIR", "~/Library/Caches/Youty")).expanduser() / "search-index.db"


@dataclass(frozen=True)
class IndexSource:
    db: Path                       # database the server opens
    snapshot: Path | None = None   # published copy `db` mirrors, if any


def locate_index() -> IndexSource:
    """Where to search: `YOUTY_INDEX_DB`, else the copy the Mac app publishes in
    the vault, else an index this process may read directly (the app's container
    when macOS allows it, or the CLI's own index). Raises `IndexUnavailable`.

    The Mac app is sandboxed: macOS blocks other programs from its container
    unless the user granted "access data from other apps" or Full Disk Access,
    and the block can return after an update. The vault copy needs neither.
    Resolved on every call, so a library created later is picked up live.
    """
    override = os.environ.get("YOUTY_INDEX_DB")
    if override:
        return IndexSource(Path(override).expanduser())
    snapshot = find_snapshot()
    if snapshot is not None:
        return IndexSource(working_db(), snapshot)
    for direct in (_container_db(), _plain_db()):
        if _readable(direct):
            return IndexSource(direct)
    if _container_db().exists():
        raise IndexUnavailable(BLOCKED)
    raise IndexUnavailable(NOT_FOUND)


def _readable(path: Path) -> bool:
    """True when this process may open the file. macOS privacy blocks still
    report that the file exists, so test with a real read."""
    try:
        with path.open("rb") as handle:
            handle.read(1)
        return True
    except OSError:
        return False


_discovered: dict[str, Any] = {"snapshot": None, "checked": float("-inf")}


def find_snapshot() -> Path | None:
    """The newest published index among the known vaults. Cheap sources first
    (env, CLI config, the last vault found); Spotlight and a bounded folder
    scan only when those find nothing, at most every `_DISCOVERY_RETRY_S`."""
    found = _newest(_snapshot_in(v) for v in _known_vaults())
    if found is not None:
        return found
    cached = _discovered["snapshot"]
    if cached is not None and cached.is_file():
        return cached
    if time.monotonic() - _discovered["checked"] < _DISCOVERY_RETRY_S:
        return None
    _discovered["checked"] = time.monotonic()
    candidates = [*_spotlight_vaults(), *(_scan_for_manifest(p, 0) for p in _FALLBACK_VAULT_PARENTS if p.exists())]
    _discovered["snapshot"] = _newest(_snapshot_in(v) for v in candidates)
    return _discovered["snapshot"]


def _known_vaults() -> list[Path]:
    vaults = []
    if os.environ.get("YOUTY_VAULT"):
        vaults.append(Path(os.environ["YOUTY_VAULT"]).expanduser())
    try:
        config = json.loads((_plain_db().parent / "cli-config.json").read_text(encoding="utf-8"))
        if isinstance(config.get("vaultPath"), str) and config["vaultPath"]:
            vaults.append(Path(config["vaultPath"]).expanduser())
    except (OSError, ValueError, AttributeError):
        pass
    return vaults


def _snapshot_in(vault: Path | None) -> Path | None:
    if vault is None:
        return None
    path = vault / SNAPSHOT
    return path if path.is_file() else None


def _newest(paths: Iterable[Path | None]) -> Path | None:
    existing = []
    for path in paths:
        try:
            if path is not None:
                existing.append((path.stat().st_mtime_ns, path))
        except OSError:
            continue
    return max(existing)[1] if existing else None


def _spotlight_vaults() -> list[Path]:
    """Vault roots Spotlight knows of (any folder holding a Youty manifest)."""
    try:
        out = subprocess.run(["/usr/bin/mdfind", "-0", "kMDItemFSName == 'manifest.json'"],
                             capture_output=True, timeout=5, check=False).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    vaults = []
    for raw in out.split(b"\0"):
        path = Path(os.fsdecode(raw)) if raw else None
        if path is not None and (path.parent / SNAPSHOT).is_file():
            vaults.append(path.parent)
    return vaults


def refresh_from_snapshot(conn: sqlite3.Connection, snapshot: Path) -> bool:
    """Mirror a newly published copy into the working database, then promote
    only what changed. Returns False when the copy is unchanged since last time.

    The indexer never edits a chunk or frame row in place: re-indexing a video
    deletes its rows and inserts new ones under fresh ids. So within one index
    (same `index_id`) the id sets alone say what changed, and a save copies
    just that video's rows instead of the whole library. A copy of a different
    index (another Mac, a reset) replaces everything.
    """
    st = snapshot.stat()
    signature = f"{st.st_ino}:{st.st_size}:{st.st_mtime_ns}"
    if _meta(conn, "snapshot_signature") == signature:
        return False
    conn.commit()
    # The copy is taken whole from the app's consistent index; checking its
    # references row by row would only reject it over a stray orphan.
    conn.execute("PRAGMA foreign_keys = OFF")
    conn.execute("ATTACH DATABASE ? AS snap", (snapshot.as_uri() + "?mode=ro",))
    try:
        # fetchall, not fetchone: an unfinished read would keep `snap` locked
        # and the DETACH below would fail.
        snap_id = conn.execute("SELECT value FROM snap.index_meta WHERE key = 'index_id'").fetchall()
        if _meta(conn, "index_id") != (snap_id[0][0] if snap_id else None):
            for table in ("chunks", "frames", "vec_chunks", "vec_frames", "chunks_fts"):
                conn.execute(f"DELETE FROM main.{table}")
        # Video rows are updated in place (title, folder), and there is one per video.
        cols = ", ".join(_common_columns(conn, "videos"))
        conn.execute("DELETE FROM main.videos")
        conn.execute(f"INSERT INTO main.videos ({cols}) SELECT {cols} FROM snap.videos")
        # Each id list is read from an index, and `+ 0` makes SQLite collect it
        # once rather than look each id up in the other table, so rows that
        # stayed the same are never read.
        for table, key in (("chunks", "chunk_id"), ("frames", "frame_id")):
            cols = ", ".join(_common_columns(conn, table))
            conn.execute(f"DELETE FROM main.{table} WHERE {key} IN (SELECT {key} FROM main.{table} "
                         f"WHERE {key} NOT IN (SELECT {key} + 0 FROM snap.{table}))")
            conn.execute(f"INSERT INTO main.{table} ({cols}) SELECT {cols} FROM snap.{table} "
                         f"WHERE {key} IN (SELECT {key} FROM snap.{table} "
                         f"WHERE {key} NOT IN (SELECT {key} + 0 FROM main.{table}))")
        own = ("fts_indexed_count", "snapshot_signature")  # the first is pre-2.0.4
        conn.execute(f"DELETE FROM main.index_meta WHERE key NOT IN {own}")
        conn.execute(f"INSERT OR REPLACE INTO main.index_meta(key, value) "
                     f"SELECT key, value FROM snap.index_meta WHERE key NOT IN {own}")
        conn.execute("INSERT OR REPLACE INTO index_meta(key, value) VALUES ('vault_root', ?)",
                     (str(snapshot.parent.parent),))
        conn.commit()
    except sqlite3.Error:
        conn.rollback()
        raise
    finally:
        conn.execute("DETACH DATABASE snap")
        conn.execute("PRAGMA foreign_keys = ON")
    _VAULT_CACHE.pop(id(conn), None)
    sync_index(conn)
    conn.execute("INSERT OR REPLACE INTO index_meta(key, value) VALUES ('snapshot_signature', ?)", (signature,))
    conn.commit()
    return True


def _meta(conn: sqlite3.Connection, key: str) -> str | None:
    rows = conn.execute("SELECT value FROM index_meta WHERE key = ?", (key,)).fetchall()
    return rows[0][0] if rows else None


def _common_columns(conn: sqlite3.Connection, table: str) -> list[str]:
    snap = {r[1] for r in conn.execute(f"PRAGMA snap.table_info({table})")}
    return [r[1] for r in conn.execute(f"PRAGMA main.table_info({table})") if r[1] in snap]


_SCHEMA_PATH = Path(__file__).parent / "schema.sql"

# Promotion DDL — additive on top of schema.sql.
_PROMOTION_DDL = """
CREATE VIRTUAL TABLE IF NOT EXISTS vec_chunks USING vec0(
    chunk_id   INTEGER PRIMARY KEY,
    embedding  float[768],
    platform   TEXT PARTITION KEY,
    chunk_type TEXT PARTITION KEY
);

CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(
    chunk_text,
    tokenize='unicode61 remove_diacritics 2'
);

CREATE VIRTUAL TABLE IF NOT EXISTS vec_frames USING vec0(
    frame_id   INTEGER PRIMARY KEY,
    embedding  float[768],
    platform   TEXT PARTITION KEY
);
"""

# Chunk and frame embeddings are both 768-d EmbeddingGemma 2 vectors in one
# space. The expected vec0 width — used to detect and rebuild a stale virtual
# table left from an older model (e.g. the 512-d MobileCLIP-S2 frame encoder).
_VEC_DIM = 768

# Possible default vault locations to scan if index_meta.vault_root is missing.
_FALLBACK_VAULT_PARENTS = [
    Path("~/Documents").expanduser(),
    Path("~/Desktop").expanduser(),
    Path("~/Library/Mobile Documents/com~apple~CloudDocs").expanduser(),
]


def open_db(db_path: Path | str) -> sqlite3.Connection:
    """Open the index DB, load sqlite-vec, apply schema + promotion idempotently."""
    path = Path(db_path)
    path.parent.mkdir(parents=True, exist_ok=True)

    # MCP SDK 2 runs synchronous tools on worker threads; the server serializes
    # every use of this connection with one lock (see server._State). `uri`
    # lets `refresh_from_snapshot` attach the published copy read-only.
    conn = sqlite3.connect(str(path), check_same_thread=False, uri=True)
    conn.row_factory = sqlite3.Row
    # The Swift app writes this same DB (WAL mode); wait briefly for its write
    # lock rather than failing when an incremental promotion lands during an
    # in-app save.
    conn.execute("PRAGMA busy_timeout=5000")
    conn.enable_load_extension(True)
    sqlite_vec.load(conn)
    conn.enable_load_extension(False)

    # Base schema (idempotent — CREATE TABLE IF NOT EXISTS everywhere).
    schema_sql = _SCHEMA_PATH.read_text(encoding="utf-8")
    conn.executescript(schema_sql)

    # Search tables left in an older shape are dropped here, so the promotion
    # DDL below recreates them and the sync repopulates them. They are derived
    # data, always rebuildable from chunks/frames.
    rebuilt = _migrate_stale_search_tables(conn)

    # Promote: vec0 + FTS5.
    conn.executescript(_PROMOTION_DDL)

    # Promote whatever the search tables are missing. The same routine runs
    # before each query (see `sync_index`), so a video saved while the server is
    # running becomes searchable without a restart, and a restart over an index
    # that is already promoted costs only a few probes.
    sync_index(conn, force=rebuilt)

    return conn


def _migrate_stale_search_tables(conn: sqlite3.Connection) -> bool:
    """Drop search tables in a shape this version doesn't maintain: a vec0 table
    at another vector width (e.g. the 512-d MobileCLIP-S2 frames), or the
    keyword index from before 2.0.4, which mirrored `chunks` as external
    content and could only be rebuilt whole. Returns True if any was dropped."""
    dropped = False
    for name in ("vec_chunks", "vec_frames", "chunks_fts"):
        row = conn.execute(
            "SELECT sql FROM sqlite_master WHERE type='table' AND name=?", (name,)
        ).fetchone()
        sql = (row["sql"] or "") if row else ""
        stale = f"float[{_VEC_DIM}]" not in sql if name != "chunks_fts" else "content=" in sql.replace(" ", "")
        if row and stale:
            conn.execute(f"DROP TABLE {name}")
            dropped = True
    return dropped


def _ids(conn: sqlite3.Connection, sql: str) -> set[int]:
    return {r[0] for r in conn.execute(sql)}


def _each_batch(conn: sqlite3.Connection, ids: set[int], sql: str) -> None:
    """Run `sql` (which reads `temp.batch`) for the ids, 2,000 at a time, so
    promoting a whole library never holds more than a batch in memory."""
    conn.execute("CREATE TEMP TABLE IF NOT EXISTS batch (id INTEGER PRIMARY KEY)")
    ordered = sorted(ids)
    for i in range(0, len(ordered), 2000):
        conn.execute("DELETE FROM temp.batch")
        conn.executemany("INSERT INTO temp.batch (id) VALUES (?)", [(x,) for x in ordered[i:i + 2000]])
        conn.execute(sql)
    conn.execute("DELETE FROM temp.batch")


# vec tables are declared float[768]; only vectors of that width fit.
_USABLE = f"embedding_dim = {_VEC_DIM} AND length(embedding) = {_VEC_DIM * 4}"


def _sync_chunks(conn: sqlite3.Connection) -> None:
    """Bring `vec_chunks` and `chunks_fts` to exactly the chunk ids in `chunks`.

    Compares id sets in Python (a join against a vec0 table is slow) and
    touches only the difference, so a save costs that video's rows."""
    base = _ids(conn, "SELECT chunk_id FROM chunks")
    vec = _ids(conn, "SELECT chunk_id FROM vec_chunks")
    fts = _ids(conn, "SELECT id FROM chunks_fts_docsize")
    conn.executemany("DELETE FROM vec_chunks WHERE chunk_id = ?", [(i,) for i in vec - base])
    conn.executemany("DELETE FROM chunks_fts WHERE rowid = ?", [(i,) for i in fts - base])
    _each_batch(conn, base - fts, "INSERT INTO chunks_fts (rowid, chunk_text) "
                                  "SELECT chunk_id, chunk_text FROM chunks WHERE chunk_id IN (SELECT id FROM temp.batch)")
    # A chunk whose video row is gone stays out of vector search, as before.
    _each_batch(conn, base - vec, "INSERT INTO vec_chunks (chunk_id, embedding, platform, chunk_type) "
                                  "SELECT c.chunk_id, c.embedding, v.platform, c.chunk_type FROM chunks c "
                                  "JOIN videos v ON v.video_id = c.video_id "
                                  f"WHERE c.chunk_id IN (SELECT id FROM temp.batch) AND c.{_USABLE}")


def _sync_frames(conn: sqlite3.Connection) -> None:
    """Bring `vec_frames` to exactly the frame ids in `frames` (see `_sync_chunks`)."""
    base = _ids(conn, "SELECT frame_id FROM frames")
    vec = _ids(conn, "SELECT frame_id FROM vec_frames")
    conn.executemany("DELETE FROM vec_frames WHERE frame_id = ?", [(i,) for i in vec - base])
    _each_batch(conn, base - vec, "INSERT INTO vec_frames (frame_id, embedding, platform) "
                                  "SELECT f.frame_id, f.embedding, v.platform FROM frames f "
                                  "JOIN videos v ON v.video_id = f.video_id "
                                  f"WHERE f.frame_id IN (SELECT id FROM temp.batch) AND f.{_USABLE}")


def sync_index(conn: sqlite3.Connection, *, force: bool = False) -> bool:
    """Incrementally promote newly-saved base rows into the vec0 + FTS5 search
    tables, and drop the entries of rows the Swift app deleted on a re-save.

    Cheap + safe to call before every query: when nothing has changed it runs
    only a few indexed COUNT/MAX probes and returns False. When the Mac app or
    CLI has saved, re-saved, or removed a video since the last call, it promotes
    just the delta — copying the embedding BLOBs the indexer already wrote, with
    no model inference — and returns True. This is what makes a video saved while
    the server is running searchable without restarting it.
    """
    if not force and not _index_changed(conn):
        return False
    _sync_chunks(conn)
    _sync_frames(conn)
    conn.commit()
    return True


def _index_changed(conn: sqlite3.Connection) -> bool:
    """Has the base index gained or lost rows since the search tables were last
    promoted? Compares base vs promoted by row COUNT (catches additions and
    deletions) and MAX id (catches re-saves, which mint new AUTOINCREMENT ids).
    The keyword index is read through its row-size table, which holds one row
    per entry. On any error returns True, so sync re-promotes defensively
    rather than serve a stale index."""
    try:
        def _agg(sql: str) -> tuple[int, int]:
            count, top = conn.execute(sql).fetchone()
            return int(count), int(top or 0)
        chunks = _agg("SELECT COUNT(*), MAX(chunk_id) FROM chunks")
        if chunks != _agg("SELECT COUNT(*), MAX(id) FROM chunks_fts_docsize"):
            return True
        vec_chunks = _agg("SELECT COUNT(*), MAX(chunk_id) FROM vec_chunks")
        frames = _agg("SELECT COUNT(*), MAX(frame_id) FROM frames")
        vec_frames = _agg("SELECT COUNT(*), MAX(frame_id) FROM vec_frames")
        # New or re-saved rows mint ids beyond what's already promoted;
        # deletions leave more promoted rows than base rows.
        return (chunks[1] > vec_chunks[1] or chunks[0] < vec_chunks[0]
                or frames[1] > vec_frames[1] or frames[0] < vec_frames[0])
    except sqlite3.Error:
        return True


# ───────── vault root resolution ─────────


_VAULT_CACHE: dict[int, Path | None] = {}
_VAULT_SCAN_MAX_DEPTH = 3  # parent/{X}/{Y}/manifest.json — enough for "Documents/Youty/<vault>"


def resolve_vault_root(conn: sqlite3.Connection) -> Path | None:
    """Resolve the absolute vault root. Persist to index_meta when discovered.

    The scan is bounded (max depth 3, skips hidden dirs) and cached per-connection
    so retrieval doesn't pay an iCloud walk on every call.
    """
    row = conn.execute(
        "SELECT value FROM index_meta WHERE key = 'vault_root'"
    ).fetchone()
    if row and row["value"]:
        p = Path(row["value"]).expanduser()
        if p.is_dir():
            _VAULT_CACHE[id(conn)] = p
            return p

    # A saved root may change while this server remains connected. Consult the
    # authoritative row first; cache only the expensive fallback scan.
    cached = _VAULT_CACHE.get(id(conn), -1)
    if cached != -1 and cached is not None and cached.is_dir():
        return cached
    if cached is None:
        return None

    for parent in _FALLBACK_VAULT_PARENTS:
        if not parent.exists():
            continue
        found = _scan_for_manifest(parent, depth=0)
        if found is not None:
            conn.execute(
                "INSERT OR REPLACE INTO index_meta(key, value) VALUES ('vault_root', ?)",
                (str(found),),
            )
            conn.commit()
            _VAULT_CACHE[id(conn)] = found
            return found

    _VAULT_CACHE[id(conn)] = None
    return None


def _scan_for_manifest(directory: Path, depth: int) -> Path | None:
    """Bounded BFS for a Youty manifest.json. Returns the manifest's parent."""
    if depth > _VAULT_SCAN_MAX_DEPTH:
        return None
    try:
        entries = list(directory.iterdir())
    except (PermissionError, OSError):
        return None

    # Check files at this level first.
    for entry in entries:
        if entry.name == "manifest.json" and entry.is_file():
            if _looks_like_youty_manifest(entry):
                return entry.parent

    # Recurse into non-hidden subdirectories.
    for entry in entries:
        if not entry.is_dir() or entry.name.startswith("."):
            continue
        # Skip well-known noisy folders to keep iCloud scans fast.
        if entry.name in {"node_modules", "Photos Library.photoslibrary", "Library"}:
            continue
        found = _scan_for_manifest(entry, depth + 1)
        if found is not None:
            return found
    return None


def _looks_like_youty_manifest(path: Path) -> bool:
    """Cheap heuristic to identify a Youty vault manifest.json."""
    try:
        head = path.read_text(encoding="utf-8", errors="ignore")[:2048]
    except (OSError, UnicodeDecodeError):
        return False
    # The app writes an array of entries with `platform` and `folder` keys;
    # older vaults wrapped them in a "videos" object.
    return ('"folder"' in head or '"videos"' in head) and (
        '"youtube"' in head or '"instagram"' in head or '"tiktok"' in head
    )


# ───────── helpers ─────────


def vector_to_blob(values: Iterable[float]) -> bytes:
    """fp32 little-endian blob — same encoding the Swift indexer writes."""
    arr = list(values)
    return struct.pack(f"<{len(arr)}f", *arr)


def blob_to_vector(blob: bytes) -> list[float]:
    """Inverse of vector_to_blob."""
    count = len(blob) // 4
    return list(struct.unpack(f"<{count}f", blob))
