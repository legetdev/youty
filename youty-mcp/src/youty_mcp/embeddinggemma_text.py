"""EmbeddingGemma text-query encoder for the `search` tool.

Used when the vault index was built with the on-device EmbeddingGemma model
(Phase S). The Mac app + CLI embed transcript chunks via a Core ML conversion
of EmbeddingGemma; this Python side embeds the user's QUERY with the same
checkpoint (`google/embeddinggemma-300m`) via sentence-transformers, so query
and document vectors share one space.

Why sentence-transformers (not raw transformers like siglip_text.py): EmbeddingGemma's
embedding is the full pipeline — mean pooling, two Dense projection heads
(768→3072→768), L2 normalize, and task-specific prompts. `encode_query` applies
all of that exactly, matching the Swift indexer's `encode_document` output space.
Skipping any stage silently degrades retrieval.

First use downloads `google/embeddinggemma-300m` from HuggingFace (one-time,
cached). The model is gated — the user must have accepted the Gemma license and
run `hf auth login` once. Embeds in ~30 ms warm on Apple Silicon (PyTorch CPU).
"""

from __future__ import annotations

import logging

import numpy as np

HF_MODEL_ID = "google/embeddinggemma-300m"
EMBEDDING_DIM = 768

_log = logging.getLogger(__name__)


class EmbeddingGemmaTextEncoder:
    """Embed query strings via EmbeddingGemma's full sentence-transformers pipeline."""

    def __init__(self) -> None:
        self._model = None  # sentence_transformers.SentenceTransformer

    def _ensure_loaded(self) -> None:
        if self._model is not None:
            return
        try:
            from sentence_transformers import SentenceTransformer
        except ImportError as exc:
            raise RuntimeError(
                "sentence-transformers is required for EmbeddingGemma search. "
                "Reinstall youty-mcp via `uv tool install youty-mcp` or `pipx install youty-mcp`."
            ) from exc

        _log.info("Loading EmbeddingGemma text encoder (%s) …", HF_MODEL_ID)
        # CPU keeps it deterministic + avoids MPS quirks; one query is fast enough.
        self._model = SentenceTransformer(HF_MODEL_ID, device="cpu")

    def embed_query(self, text: str, *, dim: int = EMBEDDING_DIM) -> list[float]:
        """Return an L2-normalized 768-d query embedding (same space as the docs)."""
        self._ensure_loaded()
        # encode_query applies EmbeddingGemma's retrieval-query task prompt.
        vec = self._model.encode_query(text, convert_to_numpy=True)
        vec = np.asarray(vec, dtype=np.float32).reshape(-1)
        vec = vec / (np.linalg.norm(vec) + 1e-9)
        return [float(x) for x in vec]
