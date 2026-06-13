-- Youty vector index schema (Phase B).
--
-- Written by the Swift indexer at save time, read by the Python MCP server
-- at query time. Lives at ~/Library/Application Support/Youty/index.db
-- (NOT inside the synced vault — the index is a rebuildable cache, the
-- vault {video.md + JPEGs} stays the portable source of truth).
--
-- Swift writes only "base" tables (videos, chunks, frames, index_meta).
-- The Python MCP server promotes data to vec0 + FTS5 virtual tables at
-- startup so the Swift side never needs to link the sqlite-vec extension.
--
-- Schema version 1.

PRAGMA journal_mode = WAL;
PRAGMA synchronous  = NORMAL;
PRAGMA foreign_keys = ON;

-- One row per saved video bundle. Mirrors fields from video.md frontmatter.
CREATE TABLE IF NOT EXISTS videos (
    video_id     TEXT PRIMARY KEY,        -- platform-qualified ("yt:abc123", "ig:DEF", "tt:7234…")
    platform     TEXT NOT NULL,           -- youtube | instagram | tiktok
    title        TEXT NOT NULL,
    channel      TEXT,
    url          TEXT NOT NULL,
    duration_ms  INTEGER,
    date_saved   INTEGER NOT NULL,        -- unix epoch milliseconds
    folder_path  TEXT NOT NULL,           -- relative to vault root, e.g. "youtube/Matt Wolfe - AI Tools"
    tags_json    TEXT,                    -- JSON array of strings
    indexed_at   INTEGER NOT NULL         -- unix epoch ms when this row was last written
);

CREATE INDEX IF NOT EXISTS idx_videos_platform   ON videos(platform);
CREATE INDEX IF NOT EXISTS idx_videos_date_saved ON videos(date_saved);

-- One row per chunk. Three types:
--   header      — structured metadata literal, no transcript content. Always 1 per video.
--   description — title + channel + caption/description, only when caption > 50 tokens.
--   body        — transcript window (~400 tokens, 60-token overlap, segment-aligned).
--
-- embedding is the raw fp32 vector as bytes (little-endian float32, length =
-- embedding_dim * 4). The Python server reads this column and copies into the
-- vec_chunks vec0 virtual table at startup.
CREATE TABLE IF NOT EXISTS chunks (
    chunk_id        INTEGER PRIMARY KEY AUTOINCREMENT,
    video_id        TEXT    NOT NULL REFERENCES videos(video_id) ON DELETE CASCADE,
    chunk_type      TEXT    NOT NULL CHECK (chunk_type IN ('header','description','body')),
    chunk_index     INTEGER NOT NULL,        -- 0 for header/description; 0..N for body
    chunk_text      TEXT    NOT NULL,        -- raw chunk text (no metadata prefix) — needed for rerank + display
    chunk_start_ms  INTEGER,                 -- NULL for header/description; ms offset for body
    chunk_end_ms    INTEGER,                 -- NULL for header/description; ms offset for body
    model_version   TEXT    NOT NULL,        -- e.g. "gemini-embedding-001@768"
    embedding_dim   INTEGER NOT NULL,
    embedding       BLOB    NOT NULL,        -- fp32 little-endian, length = embedding_dim * 4
    UNIQUE(video_id, chunk_type, chunk_index)
);

CREATE INDEX IF NOT EXISTS idx_chunks_video ON chunks(video_id);
CREATE INDEX IF NOT EXISTS idx_chunks_type  ON chunks(chunk_type);
CREATE INDEX IF NOT EXISTS idx_chunks_model ON chunks(model_version);

-- One row per kept frame (after pHash de-duplication). Written by the Swift
-- frame embedder when frames are on disk. Same fp32 BLOB convention as chunks.
CREATE TABLE IF NOT EXISTS frames (
    frame_id        INTEGER PRIMARY KEY AUTOINCREMENT,
    video_id        TEXT    NOT NULL REFERENCES videos(video_id) ON DELETE CASCADE,
    frame_ms        INTEGER NOT NULL,        -- timestamp of the frame in milliseconds
    frame_path      TEXT    NOT NULL,        -- relative to vault root
    phash           INTEGER,                 -- 64-bit perceptual hash, useful for "find visually similar"
    model_version   TEXT    NOT NULL,        -- e.g. "siglip-base-patch16-224@768"
    embedding_dim   INTEGER NOT NULL,
    embedding       BLOB    NOT NULL,
    UNIQUE(video_id, frame_ms)
);

CREATE INDEX IF NOT EXISTS idx_frames_video ON frames(video_id);
CREATE INDEX IF NOT EXISTS idx_frames_model ON frames(model_version);

-- Key/value metadata: schema version, vault path, model identifiers, last
-- rebuild timestamp, vault drift sentinel.
CREATE TABLE IF NOT EXISTS index_meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

-- Default rows; replaced on every indexer write that uses them. The text
-- default is the on-device model (Phase S default provider) so an empty,
-- never-indexed index already advertises the key-free embedding space.
INSERT OR IGNORE INTO index_meta(key, value) VALUES ('schema_version', '1');
INSERT OR IGNORE INTO index_meta(key, value) VALUES ('current_text_model',  'embeddinggemma-300m@768');
INSERT OR IGNORE INTO index_meta(key, value) VALUES ('current_frame_model', 'siglip-base-patch16-224@768');
