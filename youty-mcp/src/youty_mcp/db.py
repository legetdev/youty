"""SQLite connection + schema promotion.

The Swift indexer writes only the four base tables (videos, chunks, frames,
index_meta). At startup the MCP server idempotently promotes the data into
the vec0 virtual table `vec_chunks` and the FTS5 virtual table `chunks_fts`
so dense + sparse retrieval work without any Swift-side work.
"""

from __future__ import annotations

import os
import sqlite3
import struct
from pathlib import Path
from typing import Iterable

import sqlite_vec


def _resolve_default_db_path() -> Path:
    """Prefer the sandboxed-Mac-app container path when it exists.

    The Mac app is App-Store sandboxed, so its writes land at
    ~/Library/Containers/dev.leget.youty/Data/Library/Application Support/
    Youty/index.db. The Python MCP server isn't sandboxed, so the plain
    ~/Library/Application Support/Youty/index.db is a separate file. When
    the container DB exists we point at it — that's where real writes go.
    """
    container = Path(
        "~/Library/Containers/dev.leget.youty/Data/Library/"
        "Application Support/Youty/index.db"
    ).expanduser()
    if container.exists():
        return container
    return Path("~/Library/Application Support/Youty/index.db").expanduser()


DEFAULT_DB_PATH = _resolve_default_db_path()


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

# Frame + chunk embeddings are both 768-d (SigLIP-Base for frames since R.0b,
# on-device EmbeddingGemma for text). The expected vec0 vector width — used to detect
# and rebuild a stale virtual table left from an older model (e.g. the 512-d
# MobileCLIP-S2 frame encoder).
_VEC_DIM = 768

# Possible default vault locations to scan if index_meta.vault_root is missing.
_FALLBACK_VAULT_PARENTS = [
    Path("~/Documents").expanduser(),
    Path("~/Desktop").expanduser(),
    Path("~/Library/Mobile Documents/com~apple~CloudDocs").expanduser(),
]


def open_db(db_path: Path | str | None = None) -> sqlite3.Connection:
    """Open the index DB, load sqlite-vec, apply schema + promotion idempotently."""
    path = Path(db_path) if db_path else DEFAULT_DB_PATH
    path.parent.mkdir(parents=True, exist_ok=True)

    conn = sqlite3.connect(str(path))
    conn.row_factory = sqlite3.Row
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

    # Backfill vec_chunks for any chunks that don't yet have an entry.
    _backfill_vec_chunks(conn)

    # Backfill vec_frames for any new frame rows.
    _backfill_vec_frames(conn)

    # Drop vec0 rows whose chunk/frame no longer exists. Swift re-saves +
    # re-embeds DELETE+INSERT chunks (new AUTOINCREMENT ids), so without this the
    # vec0 tables accumulate dead vectors that dilute the dense KNN pool forever.
    _prune_orphan_vectors(conn)

    # Backfill FTS5 (content table mode handles deletes via the trigger pattern,
    # but the simplest correctness contract on startup is: ensure every chunk_id
    # has a matching FTS row).
    _backfill_fts(conn)

    conn.commit()
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
        # vec_frames is declared float[768] (SigLIP-Base); only insert matching width.
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
    We rebuild whenever the indexed chunk count diverges from the live count —
    tracked via the `fts_indexed_count` row in `index_meta`. Cheap detection,
    full correctness, idempotent on every startup.
    """
    n_chunks = int(
        conn.execute("SELECT COUNT(*) AS n FROM chunks").fetchone()["n"]
    )
    row = conn.execute(
        "SELECT value FROM index_meta WHERE key = 'fts_indexed_count'"
    ).fetchone()
    last_indexed = int(row["value"]) if row and row["value"] else -1
    if last_indexed == n_chunks:
        return
    conn.execute("INSERT INTO chunks_fts(chunks_fts) VALUES ('rebuild')")
    conn.execute(
        "INSERT OR REPLACE INTO index_meta(key, value) VALUES ('fts_indexed_count', ?)",
        (str(n_chunks),),
    )


# ───────── vault root resolution ─────────


_VAULT_CACHE: dict[int, Path | None] = {}
_VAULT_SCAN_MAX_DEPTH = 3  # parent/{X}/{Y}/manifest.json — enough for "Documents/Youty/<vault>"


def resolve_vault_root(conn: sqlite3.Connection) -> Path | None:
    """Resolve the absolute vault root. Persist to index_meta when discovered.

    The scan is bounded (max depth 3, skips hidden dirs) and cached per-connection
    so retrieval doesn't pay an iCloud walk on every call.
    """
    cached = _VAULT_CACHE.get(id(conn), -1)
    if cached != -1:
        return cached  # type: ignore[return-value]

    row = conn.execute(
        "SELECT value FROM index_meta WHERE key = 'vault_root'"
    ).fetchone()
    if row and row["value"]:
        p = Path(row["value"]).expanduser()
        if p.exists():
            _VAULT_CACHE[id(conn)] = p
            return p

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
    # Youty manifests reference platforms + the "videos" array.
    return '"videos"' in head and (
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
