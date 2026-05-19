#!/usr/bin/env python3
"""Joint-space verification: Swift-side image vectors + Python-side text
vectors must land in the same SigLIP embedding space.

Prerequisite: at least one video has been saved + frame-indexed by the
Swift indexer using the bundled SigLIP CoreML model (`youty save <url>`
without `--no-index`).

Procedure:
  1. Read one frame embedding from `frames.embedding` (written by Swift
     via FrameEmbedder + SigLIPLoader + bundled CoreML).
  2. Embed the video's `title + " " + channel` via the Python
     `SigLIPTextEncoder` (transformers.SiglipTextModel.from_pretrained()).
  3. Compute cosine. Should be positive and meaningfully higher than the
     cosine of an unrelated text query.

SigLIP cosines for matched image+caption pairs are typically in
[0.1, 0.4]; cosines for unrelated pairs are near 0 or negative. We only
assert ordering (match > unrelated), not magnitude, since the embedding
space is calibrated for sigmoid loss not raw cosine.

Run via:
    cd youty-mcp
    uv run --group dev python ../Scripts/verify-siglip-joint-space.py
"""

from __future__ import annotations

import math
import pathlib
import sqlite3
import struct
import sys


ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "youty-mcp" / "src"))

from youty_mcp.siglip_text import EMBEDDING_DIM, SigLIPTextEncoder


DB_PATH = pathlib.Path(
    "~/Library/Application Support/Youty/index.db"
).expanduser()


def cosine(a: list[float], b: list[float]) -> float:
    return sum(x * y for x, y in zip(a, b))


def main() -> int:
    if not DB_PATH.exists():
        print(f"ERROR=db_missing path={DB_PATH}", file=sys.stderr)
        return 2

    conn = sqlite3.connect(str(DB_PATH))
    conn.row_factory = sqlite3.Row

    row = conn.execute(
        """
        SELECT f.video_id, f.frame_ms, f.embedding, f.model_version,
               v.title, v.channel
        FROM frames f
        JOIN videos v ON v.video_id = f.video_id
        WHERE f.model_version = 'siglip-base-patch16-224@768'
        ORDER BY f.frame_id ASC
        LIMIT 1
        """
    ).fetchone()
    if row is None:
        print("ERROR=no_siglip_frames_in_db — run `youty save <url>` first",
              file=sys.stderr)
        return 2

    print(f"VIDEO_ID={row['video_id']}")
    print(f"TITLE={row['title']!r}")
    print(f"CHANNEL={row['channel']!r}")
    print(f"FRAME_MS={row['frame_ms']}")

    raw = row["embedding"]
    expected_bytes = EMBEDDING_DIM * 4
    if len(raw) != expected_bytes:
        print(f"ERROR=blob_size got={len(raw)} expected={expected_bytes}",
              file=sys.stderr)
        return 1
    frame_vec = list(struct.unpack(f"<{EMBEDDING_DIM}f", raw))
    norm = math.sqrt(sum(x * x for x in frame_vec))
    print(f"FRAME_L2_NORM={norm:.4f}")
    if not (0.9 < norm < 1.1):
        print(f"ERROR=frame_vec_unnormalised norm={norm}", file=sys.stderr)
        return 1

    # Embed two text queries via the Python encoder:
    #   - one semantically aligned with the saved video
    #   - one deliberately off-topic
    title_caption = f"{row['title']} by {row['channel']}"
    off_topic = "a coastal sunset over the pacific ocean"

    enc = SigLIPTextEncoder()
    print(f"Embedding match-text: {title_caption!r}")
    match_vec = enc.embed_text(title_caption)
    print(f"Embedding off-topic:  {off_topic!r}")
    miss_vec = enc.embed_text(off_topic)

    c_match = cosine(frame_vec, match_vec)
    c_miss = cosine(frame_vec, miss_vec)
    print(f"COSINE_MATCH_VS_FRAME={c_match:.4f}")
    print(f"COSINE_MISS_VS_FRAME ={c_miss:.4f}")
    print(f"DELTA={(c_match - c_miss):+.4f}")

    # Pass criteria:
    #   1. Both cosines are finite + in [-1, 1].
    #   2. Match cosine > miss cosine (joint space ordering holds).
    # We do NOT require match > 0 outright — SigLIP cosines for a single
    # mid-clip frame against a generic "title + channel" string are often
    # small (~0.05-0.15); the SIGNAL is in the ordering vs an unrelated
    # query, which is exactly what `search_frames` uses to rank results.
    for label, v in (("match", c_match), ("miss", c_miss)):
        if not math.isfinite(v) or v < -1.0 or v > 1.0:
            print(f"ERROR=cosine_{label}_out_of_range value={v}",
                  file=sys.stderr)
            return 1

    if c_match <= c_miss:
        print(f"ERROR=joint_space_ordering_fails match={c_match} <= miss={c_miss}",
              file=sys.stderr)
        return 1

    print("JOINT_SPACE_OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
