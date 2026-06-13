#!/usr/bin/env python3
"""Phase S.1 — compile Gemma's tokenizer.json into a compact binary artifact.

The raw tokenizer.json is ~32 MB; parsing it on every one-shot `youty save` is
too slow. This emits two small, fast-loading binaries the Swift tokenizer reads:

  vocab.bin   — header u32 count, then per id (0..count-1): u32 byte-length + UTF-8.
                Index == token id. Lets Swift build a token->id map + derive the
                256 <0xNN> byte-token ids and single-character ids.
  merges.bin  — header u32 count, then per merge in RANK order: (i32 a_id, i32 b_id,
                i32 merged_id). BPE runs on token ids: byte-fallback is applied when
                building the initial id sequence, so every symbol is a vocab id and
                merges are pure id-pair -> merged-id lookups.

Run from repo root (after the tokenizer.json is in place):
    python3 Scripts/build-gemma-tokenizer-artifact.py
"""

from __future__ import annotations

import json
import struct
import sys
from pathlib import Path

TOK_DIR = Path(__file__).resolve().parent.parent / "Vendor/embeddinggemma/tokenizer"


def main() -> int:
    data = json.loads((TOK_DIR / "tokenizer.json").read_text())
    model = data["model"]
    vocab: dict[str, int] = model["vocab"]
    merges = model["merges"]

    n = len(vocab)
    id2tok: list[str | None] = [None] * n
    for tok, i in vocab.items():
        id2tok[i] = tok
    if any(t is None for t in id2tok):
        print("error: vocab has id gaps", file=sys.stderr)
        return 1

    with (TOK_DIR / "vocab.bin").open("wb") as f:
        f.write(struct.pack("<I", n))
        for tok in id2tok:
            b = tok.encode("utf-8")
            f.write(struct.pack("<I", len(b)))
            f.write(b)

    written = skipped = 0
    with (TOK_DIR / "merges.bin").open("wb") as f:
        f.write(struct.pack("<I", len(merges)))  # provisional; rewrite below
        for pair in merges:
            a, b = pair if isinstance(pair, list) else pair.split(" ", 1)
            merged = a + b
            if a not in vocab or b not in vocab or merged not in vocab:
                skipped += 1
                continue
            f.write(struct.pack("<iii", vocab[a], vocab[b], vocab[merged]))
            written += 1
        f.seek(0)
        f.write(struct.pack("<I", written))  # real count

    # added_tokens.bin — every added/special token string -> id, so the Swift
    # tokenizer can split them out of input text exactly as HF does (e.g. a literal
    # "<bos>" in text becomes id 2, not BPE-tokenized). Format: u32 count, then per
    # entry u32 id + u32 len + UTF-8.
    added = data.get("added_tokens", [])
    with (TOK_DIR / "added_tokens.bin").open("wb") as f:
        f.write(struct.pack("<I", len(added)))
        for t in added:
            b = t["content"].encode("utf-8")
            f.write(struct.pack("<I", t["id"]))
            f.write(struct.pack("<I", len(b)))
            f.write(b)

    vb = (TOK_DIR / "vocab.bin").stat().st_size / 1e6
    mb = (TOK_DIR / "merges.bin").stat().st_size / 1e6
    print(f"vocab.bin: {n} tokens ({vb:.1f} MB) · merges.bin: {written} merges "
          f"(skipped {skipped}) ({mb:.1f} MB) · added_tokens.bin: {len(added)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
