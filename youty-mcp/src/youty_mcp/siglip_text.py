"""SigLIP-Base text encoder (on-device, Core ML) for the `search_frames` tool.

Embeds a natural-language query into the joint vision-text space the saved frame
vectors live in, using a Core ML conversion of SigLIP-Base's text tower (loaded
with `coremltools`, CPU) — no torch. Tokenization uses the proven HF
SiglipTokenizer (SentencePiece). SigLIP's text tower uses a fixed 64-token
context; output is L2-normalised so cosine against the frame vectors works.
"""
from __future__ import annotations

import logging
import threading

import numpy as np

from . import coreml_models

HF_TOKENIZER_ID = "google/siglip-base-patch16-224"
EMBEDDING_DIM = 768
SEQ_LEN = 64

_log = logging.getLogger(__name__)


class SigLIPTextEncoder:
    """Tokenize + embed strings via SigLIP-Base's text tower (Core ML)."""

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

            _log.info("Loading SigLIP tokenizer + Core ML text model …")
            self._tok = AutoTokenizer.from_pretrained(HF_TOKENIZER_ID)
            self._model = coreml_models.load(coreml_models.SIGLIP_TEXT)

    def embed_text(self, text: str) -> list[float]:
        """Return a 768-dim L2-normalised float list. Lazy-loads the model."""
        self._ensure_loaded()
        assert self._tok is not None and self._model is not None
        ids = self._tok(
            text, padding="max_length", truncation=True, max_length=SEQ_LEN
        )["input_ids"]
        out = self._model.predict({"input_ids": np.array([ids], dtype=np.int32)})
        vec = np.asarray(next(iter(out.values())), dtype=np.float32).reshape(-1)
        if vec.size != EMBEDDING_DIM:
            raise RuntimeError(
                f"unexpected SigLIP output size: {vec.size}, expected {EMBEDDING_DIM}"
            )
        norm = float(np.linalg.norm(vec))
        if norm > 0:
            vec = vec / norm
        return vec.tolist()
