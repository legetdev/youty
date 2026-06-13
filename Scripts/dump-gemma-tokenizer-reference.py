#!/usr/bin/env -S uv run --script

# /// script
# requires-python = ">=3.10,<3.13"
# dependencies = ["transformers>=4.56", "sentencepiece>=0.2", "protobuf>=4"]
# ///

"""Phase S.1 — dump canonical HF token ids for the Swift tokenizer's bit-exact gate.

Writes branding/tok_reference.json = { text: [ids] } using the real HF tokenizer
(add_special_tokens=True -> <bos> ... <eos>). The Swift tokenizer must reproduce
every entry identically. Corpus stress-tests the cases in docs/s1-native-embedder.md
§4.3: prompts, transcripts, German, accents, CJK, emoji/ZWJ, byte-fallback,
punctuation, whitespace quirks, truncation, and the special-token strings as text.
"""

from __future__ import annotations

import json
from pathlib import Path

from transformers import AutoTokenizer

CORPUS = [
    "",
    "a",
    " ",
    "  double  spaces  ",
    " leading and trailing ",
    "title: none | text: ",
    "task: search result | query: ",
    "title: none | text: How to make ultra realistic AI videos",
    "task: search result | query: ai influencers",
    "Wie ich 1.3 Millionen Euro Umsatz gemacht habe mit TikTok",
    "Café résumé naïve — Zürich, Köln; 42% off! (β-test)",
    "Grüße über Größe: Straße, Mädchen, Fußball.",
    "emoji 😀 thumbs 👍🏽 family 👨‍👩‍👧‍👦 done",
    "CJK 日本語 中文 한국어 mixed with English",
    "symbols ~`!@#$%^&*()_+-={}[]|\\:;\"'<>,.?/",
    "numbers 0123456789 and 3.14159 and 1,000,000",
    "tabs\tand\nnewlines\r\nhere",
    "literal marker ▁ inside text",
    "<bos> <eos> <pad> as literal text not specials",
    "a very long line " + "repeat words " * 60,
]


def main() -> int:
    tok = AutoTokenizer.from_pretrained("google/embeddinggemma-300m")
    ref = {t: tok(t, add_special_tokens=True)["input_ids"] for t in CORPUS}
    out = Path(__file__).resolve().parent.parent / "branding/tok_reference.json"
    out.write_text(json.dumps(ref, ensure_ascii=False, indent=0))
    print(f"wrote {len(ref)} reference tokenizations -> {out}")
    print("sample 'a' ->", ref["a"])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
