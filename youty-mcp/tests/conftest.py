"""Shared pytest fixtures: seeded temp DB + fake vault folder."""

from __future__ import annotations

import json
import struct
from pathlib import Path

import numpy as np
import pytest

from youty_mcp import db as _db


def _vec(seed: int, dim: int = 768) -> bytes:
    rng = np.random.default_rng(seed)
    v = rng.standard_normal(dim).astype(np.float32)
    v /= np.linalg.norm(v) or 1.0
    return v.tobytes()


@pytest.fixture()
def seeded_db(tmp_path: Path) -> tuple[Path, Path]:
    """Create a temp DB with 3 fake videos × ~3 chunks each, plus a fake vault."""
    vault = tmp_path / "vault"
    vault.mkdir()
    (vault / "manifest.json").write_text(
        json.dumps({"videos": [], "platforms": ["youtube", "tiktok", "instagram"]})
    )

    folders = {
        "yt:abc123": "youtube/Matt Wolfe - Best AI Avatar Tools",
        "ig:DEF456": "instagram/heygen_official - Demo",
        "tt:789xyz":  "tiktok/aiwhisperer - Top Tools",
    }
    for vid, rel in folders.items():
        folder = vault / rel
        folder.mkdir(parents=True)
        (folder / "video.md").write_text(
            "---\n"
            f"title: \"{vid} title\"\n"
            f"channel: \"chan-{vid}\"\n"
            f"video_id: \"{vid}\"\n"
            "tags:\n  - ai\n  - tools\n"
            "---\n\n"
            "[0:00] hello world\n[7:18] here is the part about HeyGen\n"
        )
        # Fake frames at 0ms and 438000ms for body chunk midpoint resolution.
        for ms in (0, 438000, 468000):
            (folder / f"{ms:08d}.jpg").write_bytes(b"\xff\xd8\xff\xd9")

    db_path = tmp_path / "index.db"
    conn = _db.open_db(db_path)
    conn.execute(
        "INSERT OR REPLACE INTO index_meta(key, value) VALUES ('vault_root', ?)",
        (str(vault),),
    )

    # Seed videos + chunks.
    rows = [
        ("yt:abc123", "youtube", "Best AI Avatar Tools 2025", "Matt Wolfe", "https://youtube.com/watch?v=abc123",
         600_000, folders["yt:abc123"], ["ai", "avatars", "tools"]),
        ("ig:DEF456", "instagram", "HeyGen Demo Reel", "heygen_official", "https://instagram.com/p/DEF456",
         60_000, folders["ig:DEF456"], ["heygen", "ai"]),
        ("tt:789xyz", "tiktok", "Top AI Tools I Use", "aiwhisperer", "https://tiktok.com/@aiwhisperer/video/789xyz",
         29_000, folders["tt:789xyz"], ["ai", "tools"]),
    ]
    for v in rows:
        conn.execute(
            """
            INSERT INTO videos
            (video_id, platform, title, channel, url, duration_ms,
             date_saved, folder_path, tags_json, indexed_at)
            VALUES (?,?,?,?,?,?,?,?,?,?)
            """,
            (v[0], v[1], v[2], v[3], v[4], v[5], 1_715_000_000_000,
             v[6], json.dumps(v[7]), 1_715_000_000_000),
        )

    chunks = [
        # video_id, chunk_type, chunk_index, text, start_ms, end_ms, seed
        ("yt:abc123", "header", 0, "Title: Best AI Avatar Tools 2025\nChannel: Matt Wolfe", None, None, 1),
        ("yt:abc123", "description", 0, "A walk-through of HeyGen, Synthesia, and other AI avatar tools.", None, None, 2),
        ("yt:abc123", "body", 0, "The best tool I use daily is HeyGen for AI avatars.", 420_000, 480_000, 3),
        ("yt:abc123", "body", 1, "Synthesia is another great option for enterprise.", 480_000, 540_000, 4),
        ("ig:DEF456", "header", 0, "Title: HeyGen Demo Reel\nChannel: heygen_official", None, None, 5),
        ("ig:DEF456", "body", 0, "Create AI influencers easily with our platform.", 0, 30_000, 6),
        ("tt:789xyz", "header", 0, "Title: Top AI Tools I Use\nChannel: aiwhisperer", None, None, 7),
        ("tt:789xyz", "body", 0, "These are the top AI tools I use every day for content.", 0, 29_000, 8),
    ]
    for c in chunks:
        conn.execute(
            """
            INSERT INTO chunks
            (video_id, chunk_type, chunk_index, chunk_text, chunk_start_ms,
             chunk_end_ms, model_version, embedding_dim, embedding)
            VALUES (?,?,?,?,?,?,?,?,?)
            """,
            (c[0], c[1], c[2], c[3], c[4], c[5],
             "gemini-embedding-001@768", 768, _vec(c[6])),
        )
    conn.commit()
    conn.close()
    return db_path, vault
