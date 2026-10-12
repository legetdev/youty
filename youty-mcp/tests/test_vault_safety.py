"""Regression tests for vault path boundaries and renamed bundle resolution."""

import pytest

from youty_mcp import db, server


@pytest.fixture()
def state(server_state):
    """The seeded vault with keyword-only search (no models loaded)."""
    _, vault = server_state
    yield server._STATE.conn(), vault


def test_renamed_bundle_heals(state):
    """A user-renamed bundle folder is found again by its frontmatter id."""
    conn, vault = state
    original = vault / "youtube/Matt Wolfe - Best AI Avatar Tools"
    original.rename(original.with_name("renamed"))
    result = server.get_transcript("yt:abc123")
    assert "hello world" in result
    assert conn.execute("SELECT folder_path FROM videos WHERE video_id='yt:abc123'").fetchone()[0] == "youtube/renamed"


def test_frame_tools_ignore_symlinks(state, tmp_path):
    """A synced JPEG symlink must not expose unrelated local file bytes."""
    conn, vault = state
    folder = vault / "youtube/Matt Wolfe - Best AI Avatar Tools"
    secret = tmp_path / "private.txt"
    secret.write_text("not a frame")
    (folder / "00000001.jpg").symlink_to(secret)
    result = server._do_view_frames("yt:abc123", frame_ms=[1], max_frames=1)
    assert len(result) == 2
    assert result[1].data == b"\xff\xd8\xff\xd9"


def test_transcript_rejects_outside_vault_path(state, tmp_path):
    """An absolute indexed path cannot read a transcript outside the vault."""
    conn, vault = state
    outside = tmp_path / "outside"
    outside.mkdir()
    (outside / "video.md").write_text("private contents")
    conn.execute("UPDATE videos SET folder_path=? WHERE video_id='yt:abc123'", (str(outside),))
    conn.commit()
    assert "private contents" not in server.get_transcript("yt:abc123")


def test_vault_paths_cannot_escape(state, tmp_path):
    from youty_mcp.retrieval import vault_path

    _, vault = state
    outside = tmp_path / "outside"
    outside.mkdir()
    (vault / "linked").symlink_to(outside, target_is_directory=True)
    assert vault_path(vault, "linked/video.md") is None
    assert vault_path(vault, "../outside/video.md") is None


def test_empty_server_does_not_start_model_download(tmp_path, monkeypatch):
    """Starting MCP before the first save must not load or download the model."""
    import logging

    server._STATE.close()
    monkeypatch.setenv("YOUTY_INDEX_DB", str(tmp_path / "empty.db"))
    monkeypatch.setenv("YOUTY_LOG_DIR", str(tmp_path / "logs"))
    monkeypatch.setattr(db, "_FALLBACK_VAULT_PARENTS", [tmp_path])
    started = []
    monkeypatch.setattr(server.threading, "Thread", lambda **kwargs: started.append(kwargs))
    monkeypatch.setattr(server.mcp, "run", lambda **kwargs: None)
    root = logging.getLogger()
    handlers = set(root.handlers)
    previous_level = root.level
    try:
        server.main()
        assert started == []
    finally:
        for handler in set(root.handlers) - handlers:
            root.removeHandler(handler)
            handler.close()
        root.setLevel(previous_level)
