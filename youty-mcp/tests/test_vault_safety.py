"""Regression tests for vault path boundaries and renamed bundle resolution."""

import pytest

from youty_mcp import db, server


@pytest.fixture()
def state(seeded_db, monkeypatch):
    """Use a temporary vault without loading any query models."""
    db_path, vault = seeded_db
    server._STATE.close()
    monkeypatch.setenv("YOUTY_INDEX_DB", str(db_path))
    yield server._STATE.conn(), vault
    server._STATE.close()


@pytest.mark.parametrize("value", ['abc123', '"abc123"', '"yt:abc123"'])
def test_renamed_bundle_matches_exact_quoted_id(value):
    """Accept the writer's bare IDs and quoted portable IDs, never prefixes."""
    assert server._frontmatter_id_matches(f"---\nvideo_id: {value}\n---\n", "abc123")
    assert not server._frontmatter_id_matches("---\nvideo_id: abc1234\n---\n", "abc123")
    assert not server._frontmatter_id_matches("---\ntitle: video_id: abc123\n---\n", "abc123")


def test_renamed_bundle_heals_quoted_id(state):
    """The file produced by the fixture stays readable after a user rename."""
    conn, vault = state
    original = vault / "youtube/Matt Wolfe - Best AI Avatar Tools"
    original.rename(original.with_name("renamed"))
    result = server.get_transcript("yt:abc123")
    assert "error" not in result
    assert "hello world" in result["transcript"]


def test_frame_tools_ignore_symlinks(state, tmp_path):
    """A synced JPEG symlink must not expose unrelated local file bytes."""
    conn, vault = state
    folder = vault / "youtube/Matt Wolfe - Best AI Avatar Tools"
    secret = tmp_path / "private.txt"
    secret.write_text("not a frame")
    (folder / "00000001.jpg").symlink_to(secret)
    result = server._do_view_frames("yt:abc123", frame_ms=[1], max_frames=1)
    assert len(result) == 2
    assert result[1].path.name == "00000000.jpg"
    assert not any(path.endswith("00000001.jpg") for path in server.get_video("yt:abc123")["frames"])


def test_transcript_rejects_outside_vault_path(state, tmp_path):
    """An absolute indexed path cannot read a transcript outside the vault."""
    conn, vault = state
    outside = tmp_path / "outside"
    outside.mkdir()
    (outside / "video.md").write_text("private contents")
    conn.execute("UPDATE videos SET folder_path=? WHERE video_id='yt:abc123'", (str(outside),))
    conn.commit()
    result = server.get_transcript("yt:abc123")
    assert result["transcript"] != "private contents"


def test_search_paths_cannot_escape_vault(state, tmp_path):
    """Search must not suggest outside files for clients to read directly."""
    from youty_mcp.retrieval import FusedHit, hydrate_results, vault_path

    conn, vault = state
    outside = tmp_path / "outside"
    outside.mkdir()
    (vault / "linked").symlink_to(outside, target_is_directory=True)
    assert vault_path(vault, "linked/video.md") is None
    assert vault_path(vault, "../outside/video.md") is None
    conn.execute("UPDATE videos SET folder_path=? WHERE video_id='yt:abc123'", (str(outside),))
    result = hydrate_results([FusedHit(chunk_id=1, score=1)], conn, vault)[0]
    assert result["video_md_path"] is None
    assert result["frames"] == []


def test_empty_server_does_not_start_model_download(tmp_path, monkeypatch):
    """Starting MCP before the first save must not load or download encoders."""
    import logging

    server._STATE.close()
    monkeypatch.setenv("YOUTY_INDEX_DB", str(tmp_path / "empty.db"))
    monkeypatch.setenv("YOUTY_LOG_DIR", str(tmp_path / "logs"))
    monkeypatch.setattr(db, "_FALLBACK_VAULT_PARENTS", [tmp_path])
    started = []
    monkeypatch.setattr(server.threading, "Thread", lambda **kwargs: started.append(kwargs))
    monkeypatch.setattr(server.mcp, "run", lambda: None)
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
