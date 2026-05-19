"""SigLIP-Base-Patch16-224 text encoder for query embedding.

Used by the MCP server's `search_frames` tool to embed a user's natural-
language query into the same joint vision-text space the Mac app's
indexer used for the saved frame vectors. Both sides use the same source
model — `google/siglip-base-patch16-224` (Apache-2.0). The Swift indexer
ships a CoreML-converted image encoder inside the Mac app bundle; this
Python side uses HuggingFace transformers directly because:

  - transformers handles SigLIP's SentencePiece tokenizer cleanly with
    zero hand-rolled tokenization code.
  - The first-use download (~370 MB safetensors + tokenizer) happens via
    `huggingface_hub` on the user's machine — the youty-mcp wheel stays
    tiny (~31 KB).
  - Text embedding runs in ~50-80 ms per query on Apple Silicon (PyTorch
    CPU), within the MCP query budget.

L2-normalised so cosine-similarity against the Swift-side image vectors
in `vec_frames` works directly.
"""

from __future__ import annotations

import logging

import numpy as np


HF_MODEL_ID = "google/siglip-base-patch16-224"
EMBEDDING_DIM = 768

_log = logging.getLogger(__name__)


class SigLIPTextEncoder:
    """Tokenize + embed strings via SigLIP-Base's text tower."""

    def __init__(self) -> None:
        self._model = None  # transformers.SiglipTextModel
        self._tokenizer = None  # transformers.AutoTokenizer
        self._torch = None

    def _ensure_loaded(self) -> None:
        if self._model is not None:
            return
        try:
            import torch
            from transformers import AutoTokenizer, SiglipTextModel
        except ImportError as exc:
            raise RuntimeError(
                "transformers + torch are required for frame search. "
                "Reinstall youty-mcp via `uv tool install youty-mcp` or `pipx install youty-mcp`."
            ) from exc

        _log.info("Loading SigLIP text encoder (%s) …", HF_MODEL_ID)
        # AutoTokenizer picks up SigLIP's SentencePiece config automatically.
        self._tokenizer = AutoTokenizer.from_pretrained(HF_MODEL_ID)
        # SiglipTextModel is the text-only tower (no image branch loaded).
        # eval() + no_grad in `embed_text` keeps inference deterministic
        # and avoids autograd overhead.
        self._model = SiglipTextModel.from_pretrained(HF_MODEL_ID).eval()
        self._torch = torch

    def embed_text(self, text: str) -> list[float]:
        """Return a 768-dim L2-normalised float list. Lazy-loads the model."""
        self._ensure_loaded()
        assert self._tokenizer is not None and self._model is not None and self._torch is not None

        # SigLIP's text encoder is trained with a fixed 64-token context.
        # The HF tokenizer handles truncation + padding when we pass
        # padding="max_length" + truncation=True.
        inputs = self._tokenizer(
            text,
            return_tensors="pt",
            padding="max_length",
            truncation=True,
        )
        with self._torch.no_grad():
            out = self._model(**inputs)
        # SiglipTextModel returns `pooler_output` (1, 768) post-attention-pool.
        vec = out.pooler_output[0].cpu().numpy().astype(np.float32)
        if vec.size != EMBEDDING_DIM:
            raise RuntimeError(
                f"unexpected SigLIP output size: {vec.size}, expected {EMBEDDING_DIM}"
            )
        norm = float(np.linalg.norm(vec))
        if norm > 0:
            vec = vec / norm
        return vec.tolist()
