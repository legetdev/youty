#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11,<3.13"
# dependencies = [
#   "torch==2.14.1",
#   "transformers==5.19.0",
#   "sentence-transformers[image]==6.1.0",
#   "pillow",
#   "numpy",
# ]
# ///
"""Reference vectors for checking Youty's on-device EmbeddingGemma 2 pipeline.

Embeds a fixed multilingual text corpus plus the given frame images with
Google's own sentence-transformers implementation (float32, CPU) and writes
`{texts: [{input, ids, vector}], images: [{path, vector}]}`. The app's
`--embeddinggemma2-probe <file>` then requires identical token counts, text
cosine >= 0.998, and frame cosine >= 0.99 (frames are resampled by Core
Graphics rather than torchvision).

    Scripts/verify-embeddinggemma2.py out.json frame1.jpg frame2.jpg ...

Set EMBEDDINGGEMMA2_DIR to a local snapshot of google/embeddinggemma-2 to avoid
the download.
"""
from __future__ import annotations

import json
import os
import sys

REVISION = "914f7f89142e33e77833254d9c9b90c3cef7303b"
QUERY = "task: search result | query: "


def doc(title: str, text: str) -> str:
    return f"title: {title or 'none'} | text: {text}"


CORPUS = [
    QUERY + "how do I build a scroll animation website",
    QUERY + "Was sagt der russische Botschafter über die NATO?",
    QUERY + "a man dancing in a horse stable",
    doc("Let's build GPT: from scratch", "we want every token to communicate with the previous tokens, "
        "and the simplest way is to average the vectors of all the preceding positions"),
    doc("KI & Datenschutz für Unternehmen", "Es gibt den Provider, der ein KI-System baut, und den "
        "Deployer, der es beruflich nutzt. Für die meisten Unternehmen gilt die Entwarnung."),
    doc("", "Café résumé naïve — Zürich, Köln; 42% off! (β-test) emoji 😀 👍🏽 CJK 日本語 한국어"),
    doc("Codex for Everyday Work", "codex actually means book, which is a more general word than code"),
    doc("Long chunk", "and then we sum the rows so that every row adds up to one " * 30),
]


def main() -> int:
    out_path, images = sys.argv[1], sys.argv[2:]
    from sentence_transformers import SentenceTransformer

    model_id = os.environ.get("EMBEDDINGGEMMA2_DIR", "google/embeddinggemma-2")
    kwargs = {} if os.path.isdir(model_id) else {"revision": REVISION}
    model = SentenceTransformer(model_id, device="cpu", config_kwargs={"audio_config": None},
                                model_kwargs={"dtype": "float32"}, **kwargs)
    tokenizer = model.tokenizer
    texts = []
    for text in CORPUS:
        ids = tokenizer(text, add_special_tokens=True)["input_ids"]
        assert len(ids) <= 512, "Youty's Core ML text model reads at most 512 tokens"
        vector = model.encode(text, normalize_embeddings=True).tolist()
        texts.append({"input": text, "ids": ids, "vector": vector})
    frames = [{"path": path, "vector": model.encode({"image": path}, normalize_embeddings=True).tolist()}
              for path in images]
    with open(out_path, "w", encoding="utf-8") as fh:
        json.dump({"model": "google/embeddinggemma-2", "revision": REVISION,
                   "texts": texts, "images": frames}, fh, ensure_ascii=False)
    print(f"wrote {len(texts)} texts and {len(frames)} frames to {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
