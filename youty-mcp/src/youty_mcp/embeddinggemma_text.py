"""EmbeddingGemma text-query encoder (on-device, Core ML).

Embeds the user's QUERY with the *same* on-device EmbeddingGemma model the Swift
indexer used for documents, via `coremltools` — no torch, no sentence-transformers,
no ~1.2 GB HuggingFace model download. The Core ML model runs the full pipeline
internally (transformer → mean pool → Dense 768→3072→768 → L2 normalize); we just
tokenize → pad → predict.

CPU-only inference matches the int8-quantized indexer (GPU/ANE accumulate int8
matmuls in low precision and drag cosine to ~0.9). Tokenization uses the proven
HF tokenizer — same tokens the Swift `GemmaTokenizer` produces — so query and
document vectors share one space.
"""
from __future__ import annotations

import logging
import threading

import numpy as np

from . import coreml_models

HF_TOKENIZER_ID = "google/embeddinggemma-300m"
EMBEDDING_DIM = 768
SEQ_LEN = 256  # the fixed context the Core ML model was converted at
# EmbeddingGemma's retrieval-query task prompt — identical to the Swift queryPrompt.
QUERY_PROMPT = "task: search result | query: "

_log = logging.getLogger(__name__)


class EmbeddingGemmaTextEncoder:
    """Embed query strings via the on-device Core ML EmbeddingGemma model."""

    def __init__(self) -> None:
        self._model = None
        self._tok = None
        self._lock = threading.Lock()

    def _ensure_loaded(self) -> None:
        if self._model is not None:
            return
        with self._lock:
            if self._model is not None:
                return
            from transformers import AutoTokenizer

            _log.info("Loading EmbeddingGemma tokenizer + Core ML model …")
            self._tok = AutoTokenizer.from_pretrained(HF_TOKENIZER_ID)
            self._model = coreml_models.load(coreml_models.GEMMA_TEXT)

    def embed_query(self, text: str, *, dim: int = EMBEDDING_DIM) -> list[float]:
        """Return an L2-normalized 768-d query embedding (same space as docs)."""
        self._ensure_loaded()
        assert self._tok is not None and self._model is not None
        ids = self._tok(QUERY_PROMPT + text, add_special_tokens=True)["input_ids"]
        # Truncate keeping <bos> … <eos> (matches the Swift indexer + HF).
        if len(ids) > SEQ_LEN:
            ids = [ids[0]] + ids[1 : SEQ_LEN - 1] + [ids[-1]]
        iid = np.zeros((1, SEQ_LEN), np.int32)
        msk = np.zeros((1, SEQ_LEN), np.int32)
        for i, t in enumerate(ids):
            iid[0, i] = t
            msk[0, i] = 1
        out = self._model.predict({"input_ids": iid, "attention_mask": msk})
        vec = np.asarray(next(iter(out.values())), dtype=np.float32).reshape(-1)
        vec = vec / (np.linalg.norm(vec) + 1e-9)
        return [float(x) for x in vec]
