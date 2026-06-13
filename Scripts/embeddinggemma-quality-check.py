#!/usr/bin/env -S uv run --script

# /// script
# requires-python = ">=3.10,<3.13"
# dependencies = [
#   "sentence-transformers>=5.0",
#   "torch>=2.4",
#   "numpy<2",
#   "httpx",
# ]
# ///

"""Phase S.0 quality gate — EmbeddingGemma vs Gemini retrieval on the real vault.

Proxy task: each video's TITLE is a query; the correct answer is that video. We
retrieve over BODY transcript chunks only (so the model must match a natural-
language description to transcript content, not to the title chunk itself), and
report top-1 / top-5 video hit-rate for each embedder. Higher = better; if
EmbeddingGemma lands within a small tolerance of Gemini, the S.0 gate is green
(the shipped hybrid BM25+RRF only widens EmbeddingGemma's margin further).

Same-model-both-sides for fairness:
  - Gemini: document vectors reused from the existing index; query vectors via
    the API (RETRIEVAL_QUERY, 768-dim; key from Keychain service `gemini-api`).
  - EmbeddingGemma: both sides embedded locally (PyTorch), using its own
    query/document task prompts.

Run from repo root (after `hf auth login`):
    Scripts/embeddinggemma-quality-check.py
"""

from __future__ import annotations

import subprocess
import sqlite3
import sys
from pathlib import Path

import numpy as np

DB = Path.home() / (
    "Library/Containers/dev.leget.youty/Data/Library/"
    "Application Support/Youty/index.db"
)
EMBED_DIM = 768


def gemini_key() -> str:
    out = subprocess.run(
        ["security", "find-generic-password", "-s", "gemini-api", "-w"],
        capture_output=True, text=True,
    )
    key = out.stdout.strip()
    if not key:
        sys.exit("error: no Gemini key in Keychain (service 'gemini-api').")
    return key


def norm(m: np.ndarray) -> np.ndarray:
    return m / (np.linalg.norm(m, axis=1, keepdims=True) + 1e-9)


def hit_rate(Q: np.ndarray, D: np.ndarray, q_vid: list[str], d_vid: list[str], ks=(1, 5)) -> dict[int, float]:
    sims = Q @ D.T
    hits = {k: 0 for k in ks}
    for i in range(len(Q)):
        ranked = [d_vid[j] for j in np.argsort(-sims[i])]
        for k in ks:
            if q_vid[i] in ranked[:k]:
                hits[k] += 1
    return {k: hits[k] / len(Q) for k in ks}


def main() -> int:
    con = sqlite3.connect(DB)
    titles = {vid: t for vid, t in con.execute("SELECT video_id, title FROM videos")}
    rows = con.execute(
        "SELECT video_id, chunk_text, embedding FROM chunks WHERE chunk_type='body'"
    ).fetchall()
    con.close()

    d_vid = [r[0] for r in rows]
    d_text = [r[1] for r in rows]
    D_gem = norm(np.array([np.frombuffer(r[2], dtype="<f4") for r in rows], dtype=np.float32))

    body_vids = set(d_vid)
    q_vid = [v for v in titles if v in body_vids]
    q_text = [titles[v] for v in q_vid]
    print(f"→ {len(q_text)} title-queries · {len(d_text)} body chunks · {len(body_vids)} videos", flush=True)

    # --- EmbeddingGemma (local, both sides) ---
    print("→ Embedding with EmbeddingGemma (local) ...", flush=True)
    from sentence_transformers import SentenceTransformer
    st = SentenceTransformer("google/embeddinggemma-300m", device="cpu").eval()
    D_eg = norm(np.asarray(st.encode_document(d_text, convert_to_numpy=True, show_progress_bar=True), dtype=np.float32))
    Q_eg = norm(np.asarray(st.encode_query(q_text, convert_to_numpy=True), dtype=np.float32))

    # --- Gemini queries via API (docs reused from index) ---
    print("→ Embedding queries with Gemini API ...", flush=True)
    import httpx
    key = gemini_key()
    Q_gem = []
    with httpx.Client(timeout=60) as c:
        for t in q_text:
            r = c.post(
                "https://generativelanguage.googleapis.com/v1beta/models/gemini-embedding-001:embedContent",
                headers={"x-goog-api-key": key},
                json={
                    "model": "models/gemini-embedding-001",
                    "content": {"parts": [{"text": t}]},
                    "outputDimensionality": EMBED_DIM,
                    "taskType": "RETRIEVAL_QUERY",
                },
            )
            r.raise_for_status()
            Q_gem.append(r.json()["embedding"]["values"])
    Q_gem = norm(np.asarray(Q_gem, dtype=np.float32))

    gem = hit_rate(Q_gem, D_gem, q_vid, d_vid)
    eg = hit_rate(Q_eg, D_eg, q_vid, d_vid)

    print("\n=== S.0 retrieval quality (dense-only, title→transcript) ===", flush=True)
    print(f"  Gemini          top-1={gem[1]:.1%}   top-5={gem[5]:.1%}")
    print(f"  EmbeddingGemma  top-1={eg[1]:.1%}   top-5={eg[5]:.1%}")
    print(f"  Δ               top-1={(eg[1]-gem[1])*100:+.1f}pp  top-5={(eg[5]-gem[5])*100:+.1f}pp")
    verdict = "PASS" if (eg[5] >= gem[5] - 0.10 and eg[1] >= gem[1] - 0.15) else "REVIEW"
    print(f"\n  GATE: {verdict}  (dense-only; shipped hybrid BM25+RRF only improves EmbeddingGemma)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
