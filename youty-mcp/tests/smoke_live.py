"""Live smoke test: one real Gemini call.

Reads the API key from the macOS Keychain. Runs a single embed + search round
against either an existing index.db (if present) or a freshly-seeded temp DB.

Usage:  uv run python tests/smoke_live.py
"""

from __future__ import annotations

import os
import sys
import tempfile
from pathlib import Path


def main() -> int:
    # Use the real index.db if it exists, otherwise build a tiny throwaway one.
    default_db = Path("~/Library/Application Support/Youty/index.db").expanduser()
    if default_db.exists() and default_db.stat().st_size > 0:
        os.environ.setdefault("YOUTY_INDEX_DB", str(default_db))
        print(f"Using existing index: {default_db}")
    else:
        # Build the seeded DB inline.
        sys.path.insert(0, str(Path(__file__).parent))
        from conftest import _vec  # noqa: F401  — re-use fixture helper
        import sqlite3
        from youty_mcp import db as _db

        tmp = Path(tempfile.mkdtemp())
        db_path = tmp / "index.db"
        conn = _db.open_db(db_path)
        conn.execute(
            "INSERT OR REPLACE INTO index_meta(key, value) VALUES ('vault_root', ?)",
            (str(tmp),),
        )
        conn.execute(
            """INSERT INTO videos (video_id, platform, title, channel, url, duration_ms,
                date_saved, folder_path, tags_json, indexed_at)
               VALUES ('yt:smoke','youtube','Smoke Test','Smoke','https://x/y',600000,
                       1715000000000,'youtube/Smoke','[]',1715000000000)"""
        )
        conn.execute(
            """INSERT INTO chunks (video_id,chunk_type,chunk_index,chunk_text,
                chunk_start_ms,chunk_end_ms,model_version,embedding_dim,embedding)
               VALUES ('yt:smoke','body',0,'best practices on creating AI influencers',
                       0,30000,'gemini-embedding-001@768',768,?)""",
            (_vec(42),),
        )
        conn.commit()
        conn.close()
        os.environ["YOUTY_INDEX_DB"] = str(db_path)
        print(f"Using temp index: {db_path}")

    from youty_mcp import server

    try:
        out = server._do_search(
            "What are best practices on creating AI influencers, what tools should I use?",
            k=5,
        )
    except Exception as exc:  # noqa: BLE001
        print(f"FAIL: {exc}")
        return 1

    print(f"HTTP path: 200 (no exception)")
    print(f"query: {out['query']!r}")
    print(f"sub_queries: {out['sub_queries']}")
    print(f"results: {len(out['results'])}")
    print(f"ms: {out['ms']}")
    if out["results"]:
        top = out["results"][0]
        print(f"top: {top['video_id']}  score={top['score']}  title={top['title']!r}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
