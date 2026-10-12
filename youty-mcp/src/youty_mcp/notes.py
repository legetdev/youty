"""Read Youty `video.md` notes: frontmatter, description, chapters, transcript.

The note on disk is the source of truth; the index only points into it. These
helpers turn a note into what agents need without dumping the whole file:
paragraphs of spoken transcript with timestamps, the on-screen text that was
recognized in frames, and the video's own chapter list when it has one.
"""
from __future__ import annotations

import json
import re
from dataclasses import dataclass, field

_TIMESTAMP = re.compile(r"^\[(\d{1,2}(?::\d{2}){1,2}(?:\.\d+)?)\]\s*(.*)$")
_CHAPTER = re.compile(r"^\s*(?:[-•*▶►]\s*)?\(?(\d{1,2}(?::\d{2}){1,2})\)?\s*(?:[-–—:|]\s*)?(\S.{0,120})$")


@dataclass
class Note:
    frontmatter: dict[str, object]
    description: str = ""
    spoken: list[tuple[int, str]] = field(default_factory=list)
    on_screen: list[tuple[int, str]] = field(default_factory=list)


def to_ms(label: str) -> int | None:
    """'7:18', '1:02:03', or '0:04.560' → milliseconds."""
    parts = label.split(":")
    try:
        seconds = float(parts[-1])
        minutes = 0
        for part in parts[:-1]:
            minutes = minutes * 60 + int(part)
    except ValueError:
        return None
    return minutes * 60_000 + round(seconds * 1000)


def label(ms: int | None) -> str:
    """Milliseconds → 'm:ss' or 'h:mm:ss'."""
    if ms is None:
        return ""
    s = ms // 1000
    h, m, sec = s // 3600, (s % 3600) // 60, s % 60
    return f"{h}:{m:02d}:{sec:02d}" if h else f"{m}:{sec:02d}"


def _scalar(value: str) -> str:
    """Double-quoted values use JSON-compatible escapes (as the app writes them)."""
    if len(value) >= 2 and value[0] == value[-1] == '"':
        try:
            return str(json.loads(value))
        except ValueError:
            pass
    return value.strip("\"'")


def split_frontmatter(raw: str) -> tuple[dict[str, object], str]:
    """Minimal YAML frontmatter reader (`key: value`, inline lists, `- item` lists)."""
    if not raw.startswith("---"):
        return {}, raw
    end = raw.find("\n---", 3)
    if end == -1:
        return {}, raw
    fm: dict[str, object] = {}
    current: str | None = None
    for line in raw[3:end].strip().splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if line.startswith("  - ") and current:
            value = fm.setdefault(current, [])
            if isinstance(value, list):
                value.append(line[4:].strip().strip("\"'"))
            continue
        if ":" not in line:
            current = None
            continue
        key, _, value = line.partition(":")
        key, value = key.strip(), value.strip()
        if not value:
            current = key
            fm[key] = []
        elif value.startswith("[") and value.endswith("]"):
            current = None
            try:
                fm[key] = [str(v) for v in json.loads(value)]
            except ValueError:
                fm[key] = [v.strip().strip("\"'") for v in value[1:-1].split(",") if v.strip()]
        else:
            current = None
            fm[key] = _scalar(value)
    return fm, raw[end + 4:].lstrip("\n")


def parse(raw: str) -> Note:
    fm, body = split_frontmatter(raw)
    note = Note(fm)
    section = None
    description: list[str] = []
    for line in body.splitlines():
        if line.startswith("## "):
            section = line[3:].strip().lower()
            continue
        if section in ("description", "caption", "summary"):
            description.append(line)
            continue
        match = _TIMESTAMP.match(line.strip())
        if not match or not match.group(2).strip():
            continue
        ms = to_ms(match.group(1))
        if ms is None:
            continue
        if section == "transcript":
            note.spoken.append((ms, match.group(2).strip()))
        elif section == "on-screen text":
            note.on_screen.append((ms, match.group(2).strip()))
    note.description = "\n".join(description).strip()
    return note


def chapters(description: str) -> list[tuple[int, str]]:
    """The creator's chapter list from a description ('0:00 Intro', …), if any."""
    found = []
    for line in description.splitlines():
        match = _CHAPTER.match(line)
        if match and (ms := to_ms(match.group(1))) is not None:
            found.append((ms, match.group(2).strip()))
    ordered = all(a[0] < b[0] for a, b in zip(found, found[1:]))
    return found if len(found) >= 2 and found[0][0] <= 10_000 and ordered else []


def paragraphs(segments: list[tuple[int, str]], span_ms: int = 45_000) -> list[tuple[int, str]]:
    """Caption fragments merged into ~45-second paragraphs, each with its start."""
    out: list[tuple[int, str]] = []
    start, parts = None, []
    for ms, text in segments:
        if start is None:
            start = ms
        elif ms - start >= span_ms and parts:
            out.append((start, " ".join(parts)))
            start, parts = ms, []
        parts.append(text)
    if parts and start is not None:
        out.append((start, " ".join(parts)))
    return out
