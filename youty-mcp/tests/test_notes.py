"""Parsing Youty notes: timestamps, chapters, paragraphs, frontmatter."""

from youty_mcp import notes


def test_timestamps_with_and_without_milliseconds():
    assert notes.to_ms("7:18") == 438_000
    assert notes.to_ms("1:02:03") == 3_723_000
    assert notes.to_ms("0:04.560") == 4_560
    assert notes.to_ms("x:10") is None
    assert notes.label(438_000) == "7:18" and notes.label(3_723_000) == "1:02:03"


def test_parse_reads_sections_and_frontmatter():
    raw = ("---\ntitle: \"\\\"A\\\", B\"\ntags: [\"x, y\", \"z\"]\ntranscript_source: on-device speech recognition\n---\n\n"
           "## Description\n\nHello\n\n## Transcript\n\n[0:00.000] one\n[0:05.500] two\n\n"
           "## On-screen text\n<!-- youty:on-screen-text v2 -->\n\n[0:03] slide\n")
    note = notes.parse(raw)
    assert note.frontmatter["title"] == '"A", B'
    assert note.frontmatter["tags"] == ["x, y", "z"]
    assert note.description == "Hello"
    assert note.spoken == [(0, "one"), (5_500, "two")]
    assert note.on_screen == [(3_000, "slide")]


def test_chapters_need_a_real_list():
    assert notes.chapters("0:00 Intro\n2:10 - Setup\n1:02:03 Outro") == [
        (0, "Intro"), (130_000, "Setup"), (3_723_000, "Outro")]
    assert notes.chapters("Watch at 5:00 for the best part") == []
    assert notes.chapters("2:00 late start\n3:00 end") == []


def test_paragraphs_merge_fragments():
    segments = [(i * 5_000, f"w{i}") for i in range(20)]
    merged = notes.paragraphs(segments, span_ms=45_000)
    assert merged[0] == (0, " ".join(f"w{i}" for i in range(9)))
    assert merged[1][0] == 45_000
