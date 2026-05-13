"""Light coverage of helpers that don't need a network/DB context."""

from __future__ import annotations

from youty_mcp.embedder import looks_compound
from youty_mcp.retrieval import _ms_to_label, _sanitize_fts


def test_looks_compound_long_query():
    assert looks_compound("what are best practices on creating AI influencers right now") is True


def test_looks_compound_simple_query():
    assert looks_compound("HeyGen review") is False


def test_looks_compound_conjunction():
    assert looks_compound("avatars and voice cloning") is True


def test_ms_to_label_basic():
    assert _ms_to_label(438_000) == "[7:18]"
    assert _ms_to_label(0) == "[0:00]"
    assert _ms_to_label(None) is None


def test_sanitize_fts_strips_punct():
    assert _sanitize_fts("HeyGen? ComfyUI!") == '"HeyGen" OR "ComfyUI"'
    assert _sanitize_fts("---") == ""
