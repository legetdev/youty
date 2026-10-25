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

    Row ids are stable within one index, so the vectors already promoted stay
    valid; a copy of a different index (another Mac, a reset) drops them first.
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
            conn.execute("DELETE FROM vec_chunks")
            conn.execute("DELETE FROM vec_frames")
        for table in ("videos", "chunks", "frames"):
            cols = ", ".join(_common_columns(conn, table))
            conn.execute(f"DELETE FROM main.{table}")
            conn.execute(f"INSERT INTO main.{table} ({cols}) SELECT {cols} FROM snap.{table}")
        own = ("fts_indexed_count", "snapshot_signature")
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
    sync_index(conn, force=True)
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
    content='chunks',
    content_rowid='chunk_id',
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

    # Drop any vec0 virtual table left at a stale vector width (e.g. a 512-d
    # vec_frames from the pre-R.0b MobileCLIP-S2 era) so the promotion DDL below
    # recreates it at the current 768 width and the backfill repopulates it.
    # vec0 tables are derived data — safe to rebuild from chunks/frames.
    _migrate_stale_vec_tables(conn)

    # Promote: vec0 + FTS5.
    conn.executescript(_PROMOTION_DDL)

    # Populate the search tables from the base rows (force on startup). The same
    # routine runs incrementally before each query (see `sync_index`), so a video
    # saved while the server is running becomes searchable without a restart.
    sync_index(conn, force=True)

    return conn


def _migrate_stale_vec_tables(conn: sqlite3.Connection) -> None:
    """Drop vec_chunks / vec_frames if declared at a vector width other than the
    current one (so the CREATE … IF NOT EXISTS in the promotion DDL rebuilds them
    correctly). vec0 tables are fully derivable from the base chunks/frames rows."""
    for name in ("vec_chunks", "vec_frames"):
        row = conn.execute(
            "SELECT sql FROM sqlite_master WHERE type='table' AND name=?", (name,)
        ).fetchone()
        if row and row["sql"] and f"float[{_VEC_DIM}]" not in row["sql"]:
            conn.execute(f"DROP TABLE {name}")


def _prune_orphan_vectors(conn: sqlite3.Connection) -> None:
    """Delete vec0 rows whose backing chunk/frame row is gone (deleted by a Swift
    re-save/re-embed, which mints new ids). Computed in Python + deleted by primary
    key so it works regardless of vec0's WHERE-clause support."""
    for vec_table, base_table, id_col in (
        ("vec_chunks", "chunks", "chunk_id"),
        ("vec_frames", "frames", "frame_id"),
    ):
        try:
            vec_ids = {r[0] for r in conn.execute(f"SELECT {id_col} FROM {vec_table}")}
            live_ids = {r[0] for r in conn.execute(f"SELECT {id_col} FROM {base_table}")}
        except sqlite3.OperationalError:
            continue
        for orphan in vec_ids - live_ids:
            conn.execute(f"DELETE FROM {vec_table} WHERE {id_col} = ?", (orphan,))


def _backfill_vec_chunks(conn: sqlite3.Connection) -> None:
    """Insert any chunk rows whose chunk_id is missing from vec_chunks."""
    rows = conn.execute(
        """
        SELECT c.chunk_id, c.embedding, c.embedding_dim, c.chunk_type, v.platform
        FROM chunks c
        JOIN videos v ON v.video_id = c.video_id
        LEFT JOIN vec_chunks vc ON vc.chunk_id = c.chunk_id
        WHERE vc.chunk_id IS NULL
        """
    ).fetchall()

    if not rows:
        return

    for r in rows:
        blob = r["embedding"]
        dim = r["embedding_dim"]
        # vec_chunks is declared float[768]; only insert vectors matching that width.
        if dim != _VEC_DIM or not blob or len(blob) != dim * 4:
            continue
        conn.execute(
            "INSERT INTO vec_chunks(chunk_id, embedding, platform, chunk_type) VALUES (?, ?, ?, ?)",
            (r["chunk_id"], blob, r["platform"], r["chunk_type"]),
        )


def _backfill_vec_frames(conn: sqlite3.Connection) -> None:
    """Insert any frame rows whose frame_id is missing from vec_frames."""
    rows = conn.execute(
        """
        SELECT f.frame_id, f.embedding, f.embedding_dim, v.platform
        FROM frames f
        JOIN videos v ON v.video_id = f.video_id
        LEFT JOIN vec_frames vf ON vf.frame_id = f.frame_id
        WHERE vf.frame_id IS NULL
        """
    ).fetchall()
    if not rows:
        return
    for r in rows:
        blob = r["embedding"]
        dim = r["embedding_dim"]
        # vec_frames is declared float[768]; only insert matching width.
        if dim != _VEC_DIM or not blob or len(blob) != dim * 4:
            continue
        conn.execute(
            "INSERT INTO vec_frames(frame_id, embedding, platform) VALUES (?, ?, ?)",
            (r["frame_id"], blob, r["platform"]),
        )


def _backfill_fts(conn: sqlite3.Connection) -> None:
    """Keep `chunks_fts` in sync with the external `chunks` table.

    `chunks_fts` is declared with `content='chunks'`, so the proper idiom for
    rebuilding the index is the special `('rebuild')` command rather than
    direct INSERTs (which create position-list rows but no index data).
    The caller has already detected index changes. Rebuild even when the row
    count is unchanged: re-saving a video replaces its chunks with new IDs.
    """
    n_chunks = int(
        conn.execute("SELECT COUNT(*) AS n FROM chunks").fetchone()["n"]
    )
    conn.execute("INSERT INTO chunks_fts(chunks_fts) VALUES ('rebuild')")
    conn.execute(
        "INSERT OR REPLACE INTO index_meta(key, value) VALUES ('fts_indexed_count', ?)",
        (str(n_chunks),),
    )


def sync_index(conn: sqlite3.Connection, *, force: bool = False) -> bool:
    """Incrementally promote newly-saved base rows into the vec0 + FTS5 search
    tables, and prune vectors for rows the Swift app deleted on a re-save.

    Cheap + safe to call before every query: when nothing has changed it runs
    only a few indexed COUNT/MAX probes and returns False. When the Mac app or
    CLI has saved, re-saved, or removed a video since the last call, it promotes
    just the delta — copying the embedding BLOBs the indexer already wrote, with
    no model inference — and returns True. This is what makes a video saved while
    the server is running searchable without restarting it.
    """
    if not force and not _index_changed(conn):
        return False
    _backfill_vec_chunks(conn)
    _backfill_vec_frames(conn)
    # Swift re-saves DELETE+INSERT chunks (new AUTOINCREMENT ids); drop the dead
    # vectors so they don't dilute the dense KNN pool.
    _prune_orphan_vectors(conn)
    _backfill_fts(conn)
    conn.commit()
    return True


def _index_changed(conn: sqlite3.Connection) -> bool:
    """Has the base index gained or lost rows since the search tables were last
    promoted? Compares base vs promoted by row COUNT (catches additions and
    deletions) and MAX id (catches re-saves, which mint new AUTOINCREMENT ids),
    plus the FTS5 count the keyword index tracks. On any error returns True, so
    sync re-promotes defensively rather than serve a stale index."""
    try:
        def _agg(sql: str) -> int:
            return int(conn.execute(sql).fetchone()[0])
        # New or re-saved rows mint ids beyond what's already promoted.
        if _agg("SELECT COALESCE(MAX(chunk_id), 0) FROM chunks") > \
           _agg("SELECT COALESCE(MAX(chunk_id), 0) FROM vec_chunks"):
            return True
        if _agg("SELECT COALESCE(MAX(frame_id), 0) FROM frames") > \
           _agg("SELECT COALESCE(MAX(frame_id), 0) FROM vec_frames"):
            return True
        # Deletions leave more promoted rows than base rows (orphans to prune).
        if _agg("SELECT COUNT(*) FROM chunks") < _agg("SELECT COUNT(*) FROM vec_chunks"):
            return True
        if _agg("SELECT COUNT(*) FROM frames") < _agg("SELECT COUNT(*) FROM vec_frames"):
            return True
        # Keyword index (FTS5) divergence — tracked via index_meta.
        n_chunks = _agg("SELECT COUNT(*) FROM chunks")
        row = conn.execute(
            "SELECT value FROM index_meta WHERE key='fts_indexed_count'"
        ).fetchone()
        last_fts = int(row["value"]) if row and row["value"] else -1
        return last_fts != n_chunks
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
