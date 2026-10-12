"""EmbeddingGemma 2 query encoder (on-device, Core ML on the CPU).

The Youty app embeds transcript text, on-screen text, and video frames into
one EmbeddingGemma 2 space; embedding the query with the same text model lets a
single search rank all three. The Core ML model takes token embeddings rather
than ids, so this tokenizes with Google's tokenizer, looks each id up in the
bf16 token table (× √512), and runs the 128-token function.

The CPU is deliberate: a query takes ~25 ms there, the model loads in well under
a second, and there is no multi-minute Neural Engine compilation the first time
a new AI session searches. The token table is memory-mapped and the compiled
weights are read from disk, so concurrent sessions share those pages instead of
each holding a private copy.
"""
from __future__ import annotations

import logging
import threading

import numpy as np

from . import models

_log = logging.getLogger(__name__)

MODEL_ID = "embeddinggemma-2@768"
QUERY_PROMPT = "task: search result | query: "
MAX_TOKENS = 128
_HIDDEN = 512
_SCALE = np.float32(np.sqrt(_HIDDEN))
_EOS = 1


class QueryEncoder:
    """Embed search queries into the vault's EmbeddingGemma 2 space."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._model = None
        self._tokenizer = None
        self._table: np.ndarray | None = None
        self._inputs: dict[str, np.ndarray] | None = None

    def _ensure_loaded(self) -> None:
        if self._model is not None:
            return
        import coremltools as ct
        from tokenizers import Tokenizer

        assets = models.locate()
        _log.info("Loading EmbeddingGemma 2 query model from %s", assets.text_model.parent)
        self._tokenizer = Tokenizer.from_file(str(assets.tokenizer))
        self._table = np.memmap(assets.token_table, dtype=np.uint16, mode="r").reshape(-1, _HIDDEN)
        self._model = ct.models.CompiledMLModel(
            str(assets.text_model),
            compute_units=ct.ComputeUnit.CPU_ONLY,
            function_name=f"embed_{MAX_TOKENS}",
        )
        # Core ML's Python bridge can release input arrays on a native queue
        # after predict returns; reusing buffers owned by this encoder keeps
        # that release from ever freeing a live Python array.
        self._inputs = {
            "inputs_embeds": np.zeros((1, MAX_TOKENS, _HIDDEN), np.float16),
            "attention_mask": np.zeros((1, MAX_TOKENS), np.float16),
        }

    def warm(self) -> None:
        """Load the model and run one query so the first real search is fast."""
        self.embed("warm up")

    def embed(self, query: str) -> np.ndarray:
        """L2-normalized 768-d float32 vector for `query`."""
        with self._lock:
            self._ensure_loaded()
            assert self._tokenizer is not None and self._table is not None and self._inputs is not None
            ids = self._tokenizer.encode(QUERY_PROMPT + query, add_special_tokens=True).ids
            if len(ids) > MAX_TOKENS:
                ids = ids[: MAX_TOKENS - 1] + [_EOS]
            rows = (self._table[np.asarray(ids)].astype(np.uint32) << 16).view(np.float32) * _SCALE
            embeds, mask = self._inputs["inputs_embeds"], self._inputs["attention_mask"]
            embeds.fill(0)
            mask.fill(0)
            embeds[0, : len(ids)] = rows
            mask[0, : len(ids)] = 1
            out = self._model.predict(self._inputs)
        vector = np.asarray(out["embedding"], dtype=np.float32).reshape(-1)
        return vector / (np.linalg.norm(vector) + 1e-12)
