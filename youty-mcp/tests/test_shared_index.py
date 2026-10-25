"""The server must find the index the Mac app shares in the vault, follow its
updates live, and never fail to start or answer when the index is unreachable."""

from __future__ import annotations

import asyncio
import os
import sqlite3
import sys
from pathlib import Path

import pytest
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

from youty_mcp import db, server


def publish(db_path: Path, vault: Path, index_id: str = "a" * 32) -> Path:
    """Publish the base tables the way the Mac app does (IndexStore.writeSnapshot)."""
    target = vault / ".youty" / "index.db"
    target.parent.mkdir(exist_ok=True)
    partial = target.with_name("index.db.partial")
    src = sqlite3.connect(db_path)
    src.execute("INSERT OR REPLACE INTO index_meta(key, value) VALUES ('index_id', ?)", (index_id,))
    src.commit()
    src.execute("ATTACH DATABASE ? AS snapshot", (str(partial),))
    for table in ("videos", "chunks", "frames", "index_meta"):
        src.execute(f"CREATE TABLE snapshot.{table} AS SELECT * FROM main.{table}")
    src.commit()
    src.execute("DETACH DATABASE snapshot")
    src.close()
    os.replace(partial, target)
    return target


@pytest.fixture()
def mac(tmp_path, monkeypatch):
    """A fake home with no index anywhere, and discovery limited to it."""
    home = tmp_path / "home"
    home.mkdir()
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.setenv("YOUTY_CACHE_DIR", str(tmp_path / "cache"))
    monkeypatch.delenv("YOUTY_INDEX_DB", raising=False)
    monkeypatch.delenv("YOUTY_VAULT", raising=False)
    monkeypatch.setattr(db, "_spotlight_vaults", lambda: [])
    monkeypatch.setattr(db, "_FALLBACK_VAULT_PARENTS", [])
    monkeypatch.setattr(db, "_discovered", {"snapshot": None, "checked": float("-inf")})
    server._STATE.close()
    server._STATE.__init__()
    monkeypatch.setattr(server._STATE, "embed", lambda query: None)
    yield home
    server._STATE.close()


def blocked_container(home: Path) -> Path:
    """An app index macOS won't let this process open (like a privacy block)."""
    path = home / "Library/Containers/dev.leget.youty/Data/Library/Application Support/Youty/index.db"
    path.parent.mkdir(parents=True)
    path.write_bytes(b"SQLite format 3\0")
    path.chmod(0)
    return path


def test_searches_the_index_shared_in_the_vault(mac, seeded_db, monkeypatch):
    db_path, vault = seeded_db
    publish(db_path, vault)
    blocked_container(mac)  # the shared copy wins; the blocked container is never touched
    monkeypatch.setenv("YOUTY_VAULT", str(vault))

    listing = server.list_videos()
    assert "abc123" in listing and "DEF456" in listing
    assert "HeyGen" in server.search("heygen avatar")
    assert server._STATE._path == db.working_db()
    conn = server._STATE.conn()
    assert conn.execute("SELECT COUNT(*) FROM vec_chunks").fetchone()[0] == 9
    assert db.resolve_vault_root(conn) == vault


def test_finds_the_vault_from_the_cli_config(mac, seeded_db):
    db_path, vault = seeded_db
    publish(db_path, vault)
    config = mac / "Library/Application Support/Youty/cli-config.json"
    config.parent.mkdir(parents=True)
    config.write_text(f'{{"vaultPath": "{vault}"}}')

    assert "abc123" in server.list_videos()


def test_finds_the_vault_by_its_manifest(mac, seeded_db, monkeypatch):
    db_path, vault = seeded_db
    publish(db_path, vault)
    # The manifest exactly as the app writes it: an array of entries.
    (vault / "manifest.json").write_text(
        '[\n  {\n    "channel" : "Matt Wolfe",\n    "folder" : "youtube\\/Matt Wolfe - Best AI Avatar Tools",\n'
        '    "platform" : "youtube",\n    "title" : "Best AI Avatar Tools 2025"\n  }\n]')
    monkeypatch.setattr(db, "_FALLBACK_VAULT_PARENTS", [vault.parent])

    assert "abc123" in server.list_videos()


def test_follows_new_publishes_without_a_restart(mac, seeded_db, monkeypatch):
    db_path, vault = seeded_db
    publish(db_path, vault)
    monkeypatch.setenv("YOUTY_VAULT", str(vault))
    assert "tt:789xyz" in server.list_videos()
    conn = server._STATE.conn()
    marker = bytes(768 * 4)  # proves unchanged vectors are kept, not rebuilt
    conn.execute("UPDATE vec_chunks SET embedding = ? WHERE chunk_id = 1", (marker,))
    conn.commit()

    app = sqlite3.connect(db_path)
    app.execute("DELETE FROM chunks WHERE video_id = 'tt:789xyz'")
    app.execute("DELETE FROM videos WHERE video_id = 'tt:789xyz'")
    app.commit()
    app.close()
    publish(db_path, vault)

    assert "tt:789xyz" not in server.list_videos()
    assert conn.execute("SELECT COUNT(*) FROM vec_chunks").fetchone()[0] == 7  # its header and body chunk are gone
    assert conn.execute("SELECT embedding FROM vec_chunks WHERE chunk_id = 1").fetchone()[0] == marker
    assert "tt:789xyz" not in server.search("top AI tools I use every day")


def test_a_different_index_replaces_every_vector(mac, seeded_db, monkeypatch):
    db_path, vault = seeded_db
    publish(db_path, vault)
    monkeypatch.setenv("YOUTY_VAULT", str(vault))
    conn = server._STATE.conn()
    conn.execute("UPDATE vec_chunks SET embedding = ? WHERE chunk_id = 1", (bytes(768 * 4),))
    conn.commit()

    publish(db_path, vault, index_id="b" * 32)
    server.list_videos()
    stored = conn.execute("SELECT embedding FROM chunks WHERE chunk_id = 1").fetchone()[0]
    assert conn.execute("SELECT embedding FROM vec_chunks WHERE chunk_id = 1").fetchone()[0] == stored


def test_a_damaged_publish_keeps_the_last_good_copy(mac, seeded_db, monkeypatch):
    db_path, vault = seeded_db
    target = publish(db_path, vault)
    monkeypatch.setenv("YOUTY_VAULT", str(vault))
    assert "abc123" in server.list_videos()

    target.write_bytes(b"not a database")
    assert "abc123" in server.list_videos()


def test_blocked_index_is_explained_then_recovers(mac, seeded_db, monkeypatch):
    db_path, vault = seeded_db
    blocked_container(mac)
    monkeypatch.setenv("YOUTY_VAULT", str(vault))

    for answer in (server.list_videos(), server.search("heygen"), server.get_video("yt:abc123")):
        assert answer == db.BLOCKED

    publish(db_path, vault)  # the updated app shares its index
    assert "abc123" in server.list_videos()


def test_no_library_is_explained(mac):
    assert server.list_videos() == db.NOT_FOUND


def test_save_is_still_handed_to_the_app_when_the_index_is_blocked(mac, monkeypatch):
    blocked_container(mac)
    opened = []
    monkeypatch.setattr(server.subprocess, "run", lambda args, **kw: opened.append(args[-1]))

    async def no_wait(_seconds):
        return None

    import anyio
    monkeypatch.setattr(anyio, "sleep", no_wait)
    answer = asyncio.run(server._do_save_video("https://youtu.be/abc12345", timeout_s=0))
    assert opened and opened[0].startswith("youty://save?url=")
    assert answer.startswith("Sent to Youty") and db.BLOCKED in answer


def test_startup_survives_an_unreadable_index_and_logs_why(mac, tmp_path, monkeypatch):
    import logging

    blocked_container(mac)
    monkeypatch.setenv("YOUTY_LOG_DIR", str(tmp_path / "logs"))
    monkeypatch.setattr(server.mcp, "run", lambda **kwargs: None)
    root = logging.getLogger()
    handlers, level = set(root.handlers), root.level
    try:
        server.main()
    finally:
        for handler in set(root.handlers) - handlers:
            root.removeHandler(handler)
            handler.close()
        root.setLevel(level)
    log = (tmp_path / "logs" / "youty-mcp.log").read_text()
    assert "index unavailable" in log and "macOS doesn't let this AI app read it" in log


def test_stdio_server_answers_when_its_index_cannot_be_opened(tmp_path):
    """The failure that hid behind "Connection closed": a real client must get
    a working server whose tools explain the problem."""
    unreadable = tmp_path / "index.db"
    unreadable.write_bytes(b"")
    unreadable.chmod(0)

    async def run():
        env = {**os.environ, "YOUTY_INDEX_DB": str(unreadable), "YOUTY_MODELS_DIR": "/nonexistent",
               "YOUTY_LOG_DIR": str(tmp_path / "logs")}
        params = StdioServerParameters(command=sys.executable, args=["-m", "youty_mcp.server"], env=env)
        async with stdio_client(params) as (read, write):
            async with ClientSession(read, write) as session:
                await session.initialize()
                result = await session.call_tool("list_videos", {})
                assert not result.is_error
                assert "Update the Youty app" in str(result.content)

    asyncio.run(asyncio.wait_for(run(), timeout=60))
