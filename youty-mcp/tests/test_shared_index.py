"""The server must find the index the Mac app shares in the vault, follow its
updates live, and never fail to start or answer when the index is unreachable."""

from __future__ import annotations

import asyncio
import os
import sqlite3
import sys
import time
from pathlib import Path

import pytest
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

from youty_mcp import db, server


def publish(db_path: Path, vault: Path, index_id: str = "a" * 32, legacy: bool = False) -> Path:
    """Publish the base tables the way the Mac app does (IndexStore.writeSnapshot);
    `legacy` writes the 2.0.3 format, without the id indexes."""
    target = vault / ".youty" / "index.db"
    target.parent.mkdir(exist_ok=True)
    partial = target.with_name("index.db.partial")
    src = sqlite3.connect(db_path)
    src.execute("INSERT OR REPLACE INTO index_meta(key, value) VALUES ('index_id', ?)", (index_id,))
    src.commit()
    src.execute("ATTACH DATABASE ? AS snapshot", (str(partial),))
    for table in ("videos", "chunks", "frames", "index_meta"):
        src.execute(f"CREATE TABLE snapshot.{table} AS SELECT * FROM main.{table}")
    if not legacy:
        src.execute("CREATE INDEX snapshot.snapshot_chunk_ids ON chunks(chunk_id)")
        src.execute("CREATE INDEX snapshot.snapshot_frame_ids ON frames(frame_id)")
        src.execute("PRAGMA snapshot.user_version = 1")
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
    monkeypatch.setattr(db, "_discovered", {"vaults": [], "checked": float("-inf")})
    monkeypatch.setattr(db, "_app_locations", lambda: [])
    monkeypatch.setattr(db, "_spotlight_apps", lambda: [])
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


def fake_app(bundle: Path, version: str, bundle_id: str = "dev.leget.youty") -> Path:
    import plistlib

    (bundle / "Contents").mkdir(parents=True)
    with (bundle / "Contents" / "Info.plist").open("wb") as handle:
        plistlib.dump({"CFBundleIdentifier": bundle_id, "CFBundleShortVersionString": version}, handle)
    return bundle


def test_a_current_app_that_has_not_shared_yet_is_not_told_to_update(mac, seeded_db, monkeypatch):
    db_path, vault = seeded_db
    blocked_container(mac)
    monkeypatch.setenv("YOUTY_VAULT", str(vault))
    app = fake_app(mac / "Applications/Youty.app", "2.0.4")
    monkeypatch.setattr(db, "_app_locations", lambda: [mac / "Missing/Youty.app", app])

    assert server.list_videos() == db.PREPARING
    publish(db_path, vault)  # the app finishes its first launch
    assert "abc123" in server.list_videos()


@pytest.mark.parametrize(("version", "bundle_id"), [("2.0.2", "dev.leget.youty"),
                                                    ("2.0.4", "com.example.other"),
                                                    ("garbage", "dev.leget.youty")])
def test_an_app_too_old_to_share_is_told_to_update(mac, version, bundle_id, monkeypatch):
    blocked_container(mac)
    app = fake_app(mac / "Applications/Youty.app", version, bundle_id)
    monkeypatch.setattr(db, "_app_locations", lambda: [app])

    assert server.list_videos() == db.BLOCKED


def test_finds_a_current_app_outside_the_applications_folders(mac, monkeypatch):
    blocked_container(mac)
    app = fake_app(mac / "Downloads/Youty.app", "2.1")
    monkeypatch.setattr(db, "_spotlight_apps", lambda: [app])

    assert server.list_videos() == db.PREPARING


def test_a_vault_found_before_its_first_share_is_picked_up_at_once(mac, seeded_db, monkeypatch):
    db_path, vault = seeded_db
    blocked_container(mac)
    (vault / "youtube").mkdir(exist_ok=True)
    (vault / "manifest.json").write_text("[]")
    lookups = []
    monkeypatch.setattr(db, "_spotlight_vaults", lambda: lookups.append(1) or [vault])

    assert server.list_videos() == db.BLOCKED
    publish(db_path, vault)  # well within the 30 s before Spotlight is asked again
    assert "abc123" in server.list_videos()
    assert len(lookups) == 1


def test_spotlight_ignores_manifests_of_other_apps(tmp_path, monkeypatch):
    other = tmp_path / "other"
    other.mkdir()
    (other / "manifest.json").write_text("{}")
    vault = tmp_path / "vault"
    (vault / "tiktok").mkdir(parents=True)
    (vault / "manifest.json").write_text("[]")
    listing = b"\0".join(str(f / "manifest.json").encode() for f in (other, vault))

    class Done:
        stdout = listing
    monkeypatch.setattr(db.subprocess, "run", lambda *args, **kwargs: Done)
    assert db._spotlight_vaults() == [vault]


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


def resave(db_path: Path, video_id: str, text: str, frame_seed: int) -> None:
    """Re-index one video the way the app does: its rows are replaced under new ids."""
    from tests.conftest import vector

    app = sqlite3.connect(db_path)
    app.execute("DELETE FROM chunks WHERE video_id = ?", (video_id,))
    app.execute("DELETE FROM frames WHERE video_id = ?", (video_id,))
    app.execute("INSERT INTO chunks (video_id, chunk_type, chunk_index, chunk_text, chunk_start_ms, chunk_end_ms, "
                "model_version, embedding_dim, embedding) VALUES (?, 'body', 0, ?, 0, 29000, ?, 768, ?)",
                (video_id, text, server.MODEL_ID, vector(frame_seed).tobytes()))
    app.execute("INSERT INTO frames (video_id, frame_ms, frame_path, phash, model_version, embedding_dim, embedding) "
                "VALUES (?, 0, 'x.jpg', 0, ?, 768, ?)", (video_id, server.MODEL_ID, vector(frame_seed + 1).tobytes()))
    app.commit()
    app.close()


def promoted(conn) -> tuple[set, set, set, set]:
    ids = lambda sql: {r[0] for r in conn.execute(sql)}  # noqa: E731
    return (ids("SELECT chunk_id FROM chunks"), ids("SELECT chunk_id FROM vec_chunks"),
            ids("SELECT rowid FROM chunks_text"), ids("SELECT frame_id FROM vec_frames"))


@pytest.mark.parametrize("legacy", [False, True], ids=["current", "2.0.3-copy"])
def test_a_resave_updates_only_that_video(mac, seeded_db, monkeypatch, legacy):
    db_path, vault = seeded_db
    publish(db_path, vault, legacy=legacy)
    monkeypatch.setenv("YOUTY_VAULT", str(vault))
    assert "These are the top AI tools" in server.search("every day for content")
    conn = server._STATE.conn()
    marker = bytes(768 * 4)  # an untouched video's vectors must survive the update
    conn.execute("UPDATE vec_chunks SET embedding = ? WHERE chunk_id = 1", (marker,))
    conn.execute("UPDATE chunks SET chunk_index = 99 WHERE chunk_id = 1")  # proves the row isn't recopied
    conn.commit()

    resave(db_path, "tt:789xyz", "Quantum gardening explained", 300)
    publish(db_path, vault, legacy=legacy)

    assert "Quantum gardening" in server.search("quantum gardening")
    assert "These are the top AI tools" not in server.search("every day for content")
    chunks, vec, fts, frames = promoted(conn)
    assert chunks == vec == fts and len(chunks) == 8
    assert frames == {r[0] for r in conn.execute("SELECT frame_id FROM frames")} and len(frames) == 3
    assert conn.execute("SELECT embedding FROM vec_chunks WHERE chunk_id = 1").fetchone()[0] == marker
    assert conn.execute("SELECT chunk_index FROM chunks WHERE chunk_id = 1").fetchone()[0] == 99


def test_a_restart_reuses_the_promoted_index(mac, seeded_db, monkeypatch):
    db_path, vault = seeded_db
    publish(db_path, vault)
    monkeypatch.setenv("YOUTY_VAULT", str(vault))
    server.list_videos()
    conn = server._STATE.conn()
    marker = bytes(768 * 4)
    conn.execute("UPDATE vec_chunks SET embedding = ? WHERE chunk_id = 1", (marker,))
    conn.commit()
    server._STATE.close()

    def no_work(_conn):
        raise AssertionError("a restart over a promoted index must not re-promote it")

    monkeypatch.setattr(db, "_sync_chunks", no_work)
    monkeypatch.setattr(db, "_sync_frames", no_work)
    reopened = db.open_db(db.working_db())
    assert db.sync_index(reopened) is False
    assert reopened.execute("SELECT embedding FROM vec_chunks WHERE chunk_id = 1").fetchone()[0] == marker
    reopened.close()


def test_runs_beside_a_server_of_an_earlier_version(server_state, seeded_db):
    """Up to 2.0.3 the server kept its keyword index in `chunks_fts`, mirroring
    `chunks` and rebuilt whole. A current server reading the same index keeps
    its own and leaves that one to the older server."""
    db_path, _ = seeded_db
    old = sqlite3.connect(db_path)
    old.execute("CREATE VIRTUAL TABLE chunks_fts USING fts5(chunk_text, content='chunks', "
                "content_rowid='chunk_id', tokenize='unicode61 remove_diacritics 2')")
    old.execute("INSERT INTO chunks_fts(chunks_fts) VALUES ('rebuild')")
    old.commit()
    before = old.execute("SELECT COUNT(*) FROM chunks_fts_docsize").fetchone()[0]
    old.close()

    assert "HeyGen" in server.search("heygen avatar")
    resave(db_path, "yt:abc123", "Completely different words now", 400)
    assert "The best tool I use daily" not in server.search("best tool I use daily")
    assert "Completely different" in server.search("completely different words")
    conn = server._STATE.conn()
    chunks, vec, fts, _ = promoted(conn)
    assert chunks == vec == fts
    # The older server's table is untouched; it rebuilds it itself.
    assert conn.execute("SELECT COUNT(*) FROM chunks_fts_docsize").fetchone()[0] == before


def test_retires_the_earlier_working_copy_once_unused(mac):
    cache = db.working_db().parent
    cache.mkdir(parents=True, exist_ok=True)
    old = cache / "search-index.db"
    old.write_bytes(b"x")
    (cache / "search-index.db-wal").write_bytes(b"x")
    db.retire_old_working_copy()
    assert old.exists(), "an earlier server may still be using it"

    month_ago = time.time() - 31 * 24 * 3600
    for f in (old, cache / "search-index.db-wal"):
        os.utime(f, (month_ago, month_ago))
    db.retire_old_working_copy()
    assert not old.exists() and not (cache / "search-index.db-wal").exists()
    assert db.working_db().name != old.name


def test_a_direct_index_follows_saves_incrementally(server_state, seeded_db):
    """The CLI-only path: the server reads the CLI's own index, no shared copy."""
    db_path, _ = seeded_db
    assert "These are the top AI tools" in server.search("every day for content")
    resave(db_path, "tt:789xyz", "Quantum gardening explained", 300)
    assert "Quantum gardening" in server.search("quantum gardening")
    assert "These are the top AI tools" not in server.search("every day for content")
    chunks, vec, fts, _ = promoted(server._STATE.conn())
    assert chunks == vec == fts
