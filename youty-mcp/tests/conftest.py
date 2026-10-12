"""Shared pytest fixtures: a seeded temp index plus a matching fake vault."""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import pytest

from youty_mcp import db as _db
from youty_mcp.query_encoder import MODEL_ID


def vector(seed: int, dim: int = 768) -> np.ndarray:
    rng = np.random.default_rng(seed)
    v = rng.standard_normal(dim).astype(np.float32)
    return v / np.linalg.norm(v)


def _note(title: str, video_id: str, lines: list[str], *, description: str = "",
          on_screen: list[str] | None = None) -> str:
    out = ["---", f'title: "{title}"', "platform: youtube", f"video_id: {video_id}",
           f"url: https://www.youtube.com/watch?v={video_id}", 'channel: "Matt Wolfe"',
           'tags: ["ai", "avatars", "tools"]', "---", ""]
    if description:
        out += ["## Description", "", description, ""]
    out += ["## Transcript", "", *lines, ""]
    if on_screen:
        out += ["## On-screen text", "<!-- youty:on-screen-text v2 -->", "", *on_screen, ""]
    return "\n".join(out)


@pytest.fixture()
def seeded_db(tmp_path: Path) -> tuple[Path, Path]:
    """Three videos (YouTube, Instagram, TikTok) with chunks, frames, and notes."""
    vault = tmp_path / "vault"
    vault.mkdir()
    (vault / "manifest.json").write_text(json.dumps({"videos": [], "platforms": ["youtube"]}))

    folders = {
        "yt:abc123": "youtube/Matt Wolfe - Best AI Avatar Tools",
        "ig:DEF456": "instagram/heygen_official - Demo",
        "tt:789xyz": "tiktok/aiwhisperer - Top Tools",
    }
    long_lines = [f"[{m}:{s:02d}] sentence number {m * 60 + s} about avatars and tools"
                  for m in range(0, 75) for s in range(0, 60, 5)]
    notes = {
        "yt:abc123": _note(
            "Best AI Avatar Tools 2025", "abc123",
            ["[0:00] hello world", "[7:18] here is the part about HeyGen", *long_lines],
            description="Tools I use.\n\n0:00 Intro\n7:18 HeyGen review\n12:00 Synthesia",
            on_screen=["[7:20] heygen.com · Create avatar"],
        ),
        "ig:DEF456": "---\ntitle: \"HeyGen Demo Reel\"\nplatform: instagram\npost_id: \"DEF456\"\n---\n\n"
                     "## Transcript\n\n[0:00.000] Create AI influencers easily\n[0:04.560] with our platform\n",
        "tt:789xyz": "---\ntitle: \"Top AI Tools I Use\"\nplatform: tiktok\npost_id: \"789xyz\"\n---\n\n"
                     "## Transcript\n\n[0:00.080] These are the top AI tools I use\n",
    }
    for vid, rel in folders.items():
        folder = vault / rel
        folder.mkdir(parents=True)
        (folder / "video.md").write_text(notes[vid])
        for ms in (0, 438000, 468000):
            (folder / f"{ms:08d}.jpg").write_bytes(b"\xff\xd8\xff\xd9")

    db_path = tmp_path / "index.db"
    conn = _db.open_db(db_path)
    conn.execute("INSERT OR REPLACE INTO index_meta(key, value) VALUES ('vault_root', ?)", (str(vault),))
    videos = [
        ("yt:abc123", "youtube", "Best AI Avatar Tools 2025", "Matt Wolfe",
         "https://www.youtube.com/watch?v=abc123", 1_800_000, ["ai", "avatars"]),
        ("ig:DEF456", "instagram", "HeyGen Demo Reel", "heygen_official",
         "https://www.instagram.com/p/DEF456/", 60_000, ["heygen"]),
        ("tt:789xyz", "tiktok", "Top AI Tools I Use", "aiwhisperer",
         "https://www.tiktok.com/@aiwhisperer/video/789xyz", 29_000, ["ai"]),
    ]
    for vid, platform, title, channel, url, duration, tags in videos:
        conn.execute(
            "INSERT INTO videos (video_id, platform, title, channel, url, duration_ms, date_saved, "
            "folder_path, tags_json, indexed_at) VALUES (?,?,?,?,?,?,?,?,?,?)",
            (vid, platform, title, channel, url, duration, 1_715_000_000_000, folders[vid],
             json.dumps(tags), 1_715_000_000_000),
        )
    chunks = [
        ("yt:abc123", "header", 0, "Best AI Avatar Tools 2025\nBy Matt Wolfe on Youtube", None, None, 1),
        ("yt:abc123", "description", 0, "A walk-through of HeyGen, Synthesia, and other avatar tools.", None, None, 2),
        ("yt:abc123", "body", 0, "The best tool I use daily is HeyGen for AI avatars.", 420_000, 480_000, 3),
        ("yt:abc123", "body", 1, "Synthesia is another great option for enterprise.", 480_000, 540_000, 4),
        ("yt:abc123", "frame_text", 0, "[7:20] heygen.com · Create avatar", 440_000, 440_000, 9),
        ("ig:DEF456", "header", 0, "HeyGen Demo Reel\nBy heygen_official on Instagram", None, None, 5),
        ("ig:DEF456", "body", 0, "Create AI influencers easily with our platform.", 0, 30_000, 6),
        ("tt:789xyz", "header", 0, "Top AI Tools I Use\nBy aiwhisperer on Tiktok", None, None, 7),
        ("tt:789xyz", "body", 0, "These are the top AI tools I use every day for content.", 0, 29_000, 8),
    ]
    for vid, ctype, index, text, start, end, seed in chunks:
        conn.execute(
            "INSERT INTO chunks (video_id, chunk_type, chunk_index, chunk_text, chunk_start_ms, chunk_end_ms, "
            "model_version, embedding_dim, embedding) VALUES (?,?,?,?,?,?,?,?,?)",
            (vid, ctype, index, text, start, end, MODEL_ID, 768, vector(seed).tobytes()),
        )
    for vid, ms, seed in [("yt:abc123", 438000, 101), ("ig:DEF456", 0, 102), ("tt:789xyz", 0, 103)]:
        conn.execute(
            "INSERT INTO frames (video_id, frame_ms, frame_path, phash, model_version, embedding_dim, embedding) "
            "VALUES (?,?,?,?,?,?,?)",
            (vid, ms, f"{folders[vid]}/{ms:08d}.jpg", 0, MODEL_ID, 768, vector(seed).tobytes()),
        )
    conn.execute("INSERT OR REPLACE INTO index_meta(key, value) VALUES ('current_text_model', ?)", (MODEL_ID,))
    conn.commit()
    conn.close()
    return db_path, vault


@pytest.fixture()
def server_state(seeded_db, monkeypatch):
    """The server bound to the seeded index, with a stub query encoder that
    returns `server_state.query_vector` (None means keyword-only search)."""
    from youty_mcp import server

    db_path, vault = seeded_db
    server._STATE.close()
    server._STATE.__init__()
    monkeypatch.setenv("YOUTY_INDEX_DB", str(db_path))

    class Stub:
        query_vector = None

    stub = Stub()
    monkeypatch.setattr(server._STATE, "embed", lambda query: stub.query_vector)
    yield stub, vault
    server._STATE.close()
