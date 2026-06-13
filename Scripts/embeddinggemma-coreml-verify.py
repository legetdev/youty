#!/usr/bin/env -S uv run --script

# /// script
# requires-python = ">=3.10,<3.13"
# dependencies = [
#   "coremltools>=8.1,<9",
#   "transformers>=4.56",
#   "sentence-transformers>=5.0",
#   "torch>=2.12",
#   "numpy<2",
# ]
# ///

"""Phase S.0 — verify the CONVERTED Core ML EmbeddingGemma retains retrieval quality.

Runs the same title->transcript proxy as embeddinggemma-quality-check.py, but
embeds every doc + query through the *Core ML* model (the shipping artifact),
applying EmbeddingGemma's own query/document task prompts and padding to the
model's fixed sequence length. If the top-1/top-5 here matches the PyTorch run
(93.1% / 96.6%), the conversion preserved full functionality.
"""

from __future__ import annotations

import sqlite3
import sys
from pathlib import Path

import numpy as np

DB = Path.home() / (
    "Library/Containers/dev.leget.youty/Data/Library/"
    "Application Support/Youty/index.db"
)
PKG = Path(__file__).resolve().parent.parent / "Vendor/embeddinggemma/models/EmbeddingGemma-300m_text.mlpackage"
SEQ = 256


def norm(m: np.ndarray) -> np.ndarray:
    return m / (np.linalg.norm(m, axis=1, keepdims=True) + 1e-9)


def hit_rate(Q, D, q_vid, d_vid, ks=(1, 5)):
    sims = Q @ D.T
    out = {}
    for k in ks:
        hits = sum(q_vid[i] in [d_vid[j] for j in np.argsort(-sims[i])[:k]] for i in range(len(Q)))
        out[k] = hits / len(Q)
    return out


def main() -> int:
    con = sqlite3.connect(DB)
    titles = {v: t for v, t in con.execute("SELECT video_id, title FROM videos")}
    rows = con.execute("SELECT video_id, chunk_text FROM chunks WHERE chunk_type='body'").fetchall()
    con.close()
    d_vid = [r[0] for r in rows]
    d_text = [r[1] for r in rows]
    body = set(d_vid)
    q_vid = [v for v in titles if v in body]
    q_text = [titles[v] for v in q_vid]
    print(f"→ {len(q_text)} queries · {len(d_text)} body chunks", flush=True)

    from sentence_transformers import SentenceTransformer
    import coremltools as ct

    st = SentenceTransformer("google/embeddinggemma-300m", device="cpu")
    tok = st.tokenizer
    prompts = st.prompts
    qp = prompts.get("query", "task: search result | query: ")
    dp = prompts.get("document", "title: none | text: ")
    print(f"→ prompts: query={qp!r}  document={dp!r}", flush=True)

    print("→ loading Core ML model ...", flush=True)
    m = ct.models.MLModel(str(PKG))

    def embed(texts, prompt):
        vecs = []
        for t in texts:
            enc = tok(prompt + t, padding="max_length", truncation=True,
                      max_length=SEQ, return_tensors="np")
            out = m.predict({
                "input_ids": enc["input_ids"].astype(np.int32),
                "attention_mask": enc["attention_mask"].astype(np.int32),
            })
            vecs.append(np.asarray(list(out.values())[0], dtype=np.float32).reshape(-1))
        return norm(np.array(vecs, dtype=np.float32))

    print("→ embedding docs via Core ML ...", flush=True)
    D = embed(d_text, dp)
    print("→ embedding queries via Core ML ...", flush=True)
    Q = embed(q_text, qp)

    r = hit_rate(Q, D, q_vid, d_vid)
    print("\n=== Core ML EmbeddingGemma retrieval (title→transcript) ===")
    print(f"  Core ML   top-1={r[1]:.1%}   top-5={r[5]:.1%}")
    print(f"  (PyTorch reference: top-1=93.1%  top-5=96.6%)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
