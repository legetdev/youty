"""The MCP tools end to end against the seeded vault (no models loaded)."""

from __future__ import annotations

import asyncio

from youty_mcp import server

from .conftest import vector


def test_search_is_compact_markdown_with_moment_links(server_state):
    stub, _ = server_state
    stub.query_vector = vector(3)
    out = server.search("which avatar tool is best")
    assert "Best AI Avatar Tools 2025" in out
    assert "Said at [7:00](https://www.youtube.com/watch?v=abc123&t=420s)" in out
    assert "`yt:abc123`" in out and "get_transcript" in out
    assert len(out) < 40_000  # well under Claude Code's 10K-token warning


def test_search_without_model_says_keyword_only(server_state):
    out = server.search("HeyGen")
    assert "keyword matching only" in out
    assert server.search("qqqqzzzz").startswith("No saved video matches")


def test_transcript_pages_and_links(server_state):
    first = server.get_transcript("yt:abc123")
    assert first.startswith("# Best AI Avatar Tools 2025")
    assert "[0:00](https://www.youtube.com/watch?v=abc123&t=0s) hello world" in first
    assert len(first) < 26_000
    assert "(Continues — get_transcript(\"yt:abc123\", start_ms=" in first
    next_ms = int(first.rsplit("start_ms=", 1)[1].split(")")[0])
    second = server.get_transcript("yt:abc123", start_ms=next_ms)
    assert f"[{server.notes.label(next_ms)}]" in second
    window = server.get_transcript("yt:abc123", start_ms=430_000, end_ms=450_000, include_on_screen_text=True)
    assert "heygen.com · Create avatar" in window and "Continues" not in window


def test_short_form_transcript_timestamps_parse(server_state):
    out = server.get_transcript("ig:DEF456")
    assert "Create AI influencers easily with our platform" in out


def test_overview_lists_creator_chapters(server_state):
    out = server.get_video("yt:abc123")
    assert "## Chapters" in out
    assert "- [7:18](https://www.youtube.com/watch?v=abc123&t=438s) HeyGen review" in out
    assert "Sections" in server.get_video("tt:789xyz")
    assert "No saved video" in server.get_video("yt:nope")


def test_view_frames_returns_images(server_state):
    result = server._do_view_frames("yt:abc123", frame_ms=[440_000], max_frames=2)
    assert "7:18" in result[0]
    assert len(result) == 2 and type(result[1]).__name__ == "Image"


def test_listing_and_similar(server_state):
    assert server.list_videos(limit=10).startswith("3 of 3 saved videos")
    assert "instagram" not in server.list_videos(platform="youtube").lower().split("saved videos:")[1].split("·")[0]
    assert "`" in server.find_similar("yt:abc123")


def test_save_video_ids_and_validation(server_state):
    assert server._expected_id("https://youtu.be/dQw4w9WgXcQ") == "yt:dQw4w9WgXcQ"
    assert server._expected_id("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=10") == "yt:dQw4w9WgXcQ"
    assert server._expected_id("youtube.com/shorts/abcDEF12345") == "yt:abcDEF12345"
    assert server._expected_id("https://www.instagram.com/reel/DEF456/") == "ig:DEF456"
    assert server._expected_id("https://www.tiktok.com/@a/video/7234567890") == "tt:7234567890"
    assert server._expected_id("https://vm.tiktok.com/ZMabc/") is None
    assert not server._supported("https://evil.example/youtube.com")
    rejected = asyncio.run(server._do_save_video("https://example.com/video"))
    assert "YouTube, Instagram, or TikTok" in rejected
    already = asyncio.run(server._do_save_video("https://www.youtube.com/watch?v=abc123"))
    assert already.startswith("Already saved as `yt:abc123`")


def test_save_video_resaves_missing_notes_and_never_guesses(server_state, monkeypatch):
    _, vault = server_state
    opened = []
    monkeypatch.setattr(server.subprocess, "run", lambda args, **kw: opened.append(args[-1]))
    for path in vault.rglob("video.md"):
        if "abc123" in path.read_text():
            path.unlink()
    # The index still lists the video, but its note is gone: hand it to the app again.
    pending = asyncio.run(server._do_save_video("https://www.youtube.com/watch?v=abc123", timeout_s=0))
    assert opened and "abc123" in opened[-1] and "still working" in pending
    # A short link that can't be expanded is sent, but never matched to an unrelated video.
    monkeypatch.setattr(server, "_expand_short_link", lambda url: None)
    sent = asyncio.run(server._do_save_video("https://vm.tiktok.com/ZMabc/"))
    assert sent.startswith("Sent to Youty") and "vm.tiktok.com" in opened[-1]


def test_instructions_fit_client_limit():
    assert len(server.INSTRUCTIONS) < 2048
