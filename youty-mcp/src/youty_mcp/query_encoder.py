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

Only Core ML's native runtime library is loaded, not the `coremltools` package:
importing the package pulls in its whole model-conversion toolkit (about two
seconds), which would put a fresh helper process well over a second. This
encoder runs in that short-lived helper (see `query_worker`), so the server
itself never holds the model.
"""
from __future__ import annotations

import importlib.machinery
import importlib.util
import logging
import threading
from pathlib import Path

import numpy as np

from . import models
from .gemma_tokenizer import FILES as _COMPACT_TOKENIZER, GemmaTokenizer

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
        assets = models.locate()
        _log.info("Loading EmbeddingGemma 2 query model from %s", assets.text_model.parent)
        self._tokenizer = _load_tokenizer(assets.tokenizer)
        self._table = np.memmap(assets.token_table, dtype=np.uint16, mode="r").reshape(-1, _HIDDEN)
        self._model = _load_model(assets.text_model, f"embed_{MAX_TOKENS}")
        # Core ML's Python bridge can release input arrays on a native queue
        # after predict returns; reusing buffers owned by this encoder keeps
        # that release from ever freeing a live Python array. Float32 is what
        # coremltools itself hands the runtime for this model's float16 inputs.
        self._inputs = {
            "inputs_embeds": np.zeros((1, MAX_TOKENS, _HIDDEN), np.float32),
            "attention_mask": np.zeros((1, MAX_TOKENS), np.float32),
        }

    def warm(self) -> None:
        """Load the model and run one query so the first real search is fast."""
        self.embed("warm up")

    def embed(self, query: str) -> np.ndarray:
        """L2-normalized 768-d float32 vector for `query`."""
        with self._lock:
            self._ensure_loaded()
            assert self._tokenizer is not None and self._table is not None and self._inputs is not None
            ids = self._tokenizer(QUERY_PROMPT + query)
            if len(ids) > MAX_TOKENS:
                ids = ids[: MAX_TOKENS - 1] + [_EOS]
            rows = (self._table[np.asarray(ids)].astype(np.uint32) << 16).view(np.float32) * _SCALE
            embeds, mask = self._inputs["inputs_embeds"], self._inputs["attention_mask"]
            embeds.fill(0)
            mask.fill(0)
            embeds[0, : len(ids)] = rows
            mask[0, : len(ids)] = 1
            out = self._model.predict(self._inputs, None)
        vector = np.asarray(out["embedding"], dtype=np.float32).reshape(-1)
        return vector / (np.linalg.norm(vector) + 1e-12)


def _load_tokenizer(tokenizer_json: Path):
    """Text → token ids (with <bos>/<eos>). Prefers the compact artifacts every
    install ships next to `tokenizer.json`; the JSON takes over half a second."""
    if all((tokenizer_json.parent / name).exists() for name in _COMPACT_TOKENIZER):
        return GemmaTokenizer(tokenizer_json.parent).encode
    from tokenizers import Tokenizer

    tokenizer = Tokenizer.from_file(str(tokenizer_json))
    return lambda text: tokenizer.encode(text, add_special_tokens=True).ids


def _load_model(path: Path, function: str):
    """A CPU-only Core ML model with a `predict(inputs, state)` method.

    Loads `coremltools`' native runtime library directly and falls back to the
    full package if a future version lays it out differently.
    """
    try:
        spec = importlib.util.find_spec("coremltools")
        location = Path(spec.submodule_search_locations[0]) / "libcoremlpython.so"  # type: ignore[union-attr,index]
        name = "coremltools.libcoremlpython"
        loader = importlib.machinery.ExtensionFileLoader(name, str(location))
        native = importlib.util.module_from_spec(importlib.util.spec_from_loader(name, loader))  # type: ignore[arg-type]
        loader.exec_module(native)
        return native._MLModelProxy(str(path), "CPU_ONLY", function, {}, None)
    except Exception as exc:  # noqa: BLE001
        _log.info("native Core ML runtime unavailable (%s); loading coremltools", exc)
        import coremltools as ct

        return ct.models.CompiledMLModel(str(path), compute_units=ct.ComputeUnit.CPU_ONLY,
                                         function_name=function)._proxy
