"""MobileCLIP-S2 text encoder, loaded via `coremltools` on Apple Silicon.

Lazy-downloads the CoreML model package + tokenizer files (~127 MB image
weights + ~127 MB text weights ~+ 1.5 MB vocab/merges) into the shared
`~/Library/Application Support/Youty/models/` directory the Swift app
also uses. Outputs 512-dim L2-normalised float vectors.
"""

from __future__ import annotations

import logging
import os
import urllib.request
from pathlib import Path
from typing import Iterable

import numpy as np

from .clip_tokenizer import CLIPTokenizer


_MODEL_DIR_DEFAULT = Path(
    "~/Library/Application Support/Youty/models"
).expanduser()

# When running inside the sandboxed app container, the Swift side wrote to a
# different path; try the unsandboxed location first, then the sandboxed
# fallback so a single live system can share weights.
_SANDBOXED_DIR = Path(
    "~/Library/Containers/dev.leget.youty/Data/Library/Application Support/Youty/models"
).expanduser()


MOBILECLIP_TEXT_PKG_FILES = [
    ("Manifest.json", 617),
    ("Data/com.apple.CoreML/model.mlmodel", 128_127),
    ("Data/com.apple.CoreML/weights/weight.bin", 126_866_880),
]
_HF_BASE = "https://huggingface.co/apple/coreml-mobileclip/resolve/main/mobileclip_s2_text.mlpackage"
_VOCAB_URL = "https://huggingface.co/openai/clip-vit-base-patch32/resolve/main/vocab.json"
_MERGES_URL = "https://huggingface.co/openai/clip-vit-base-patch32/resolve/main/merges.txt"

EMBEDDING_DIM = 512

_log = logging.getLogger(__name__)


class MobileCLIPTextEncoder:
    """Tokenize + embed strings via the MobileCLIP-S2 CoreML text model."""

    def __init__(self, model_dir: Path | None = None) -> None:
        self._dir = model_dir or _resolve_model_dir()
        self._tokenizer: CLIPTokenizer | None = None
        self._model = None  # coremltools.models.MLModel

    def _ensure_model(self) -> None:
        if self._model is not None:
            return
        try:
            import coremltools as ct
        except ImportError as exc:
            raise RuntimeError(
                "coremltools is required for frame search. Install with `uv sync`."
            ) from exc

        pkg = self._dir / "mobileclip_s2_text.mlpackage"
        _ensure_package(pkg, _HF_BASE, MOBILECLIP_TEXT_PKG_FILES)
        # ML Program models load directly from the .mlpackage dir.
        self._model = ct.models.MLModel(str(pkg))

    def _ensure_tokenizer(self) -> None:
        if self._tokenizer is not None:
            return
        vocab = self._dir / "clip_vocab.json"
        merges = self._dir / "clip_merges.txt"
        _ensure_file(vocab, _VOCAB_URL)
        _ensure_file(merges, _MERGES_URL)
        self._tokenizer = CLIPTokenizer(vocab, merges)

    def embed_text(self, text: str) -> list[float]:
        """Return a 512-d L2-normalised float list. Lazy-loads model + tokenizer."""
        self._ensure_tokenizer()
        self._ensure_model()
        assert self._tokenizer is not None and self._model is not None

        ids = self._tokenizer.encode_full(text)
        arr = np.array([ids], dtype=np.int32)  # shape [1, 77]
        out = self._model.predict({"text": arr})
        # CoreML returns FLOAT16 ndarray; cast + normalise.
        vec = np.asarray(out["final_emb_1"], dtype=np.float32).reshape(-1)
        if vec.size != EMBEDDING_DIM:
            raise RuntimeError(
                f"unexpected MobileCLIP output size: {vec.size}, expected {EMBEDDING_DIM}"
            )
        norm = float(np.linalg.norm(vec))
        if norm > 0:
            vec = vec / norm
        return vec.astype(np.float32).tolist()


def _resolve_model_dir() -> Path:
    """Prefer an existing dir; allow `YOUTY_MODELS_DIR` to override."""
    override = os.environ.get("YOUTY_MODELS_DIR")
    if override:
        p = Path(override).expanduser()
        p.mkdir(parents=True, exist_ok=True)
        return p
    if _SANDBOXED_DIR.exists() and any(_SANDBOXED_DIR.iterdir()):
        return _SANDBOXED_DIR
    _MODEL_DIR_DEFAULT.mkdir(parents=True, exist_ok=True)
    return _MODEL_DIR_DEFAULT


def _ensure_file(dest: Path, url: str, expected_size: int | None = None) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists():
        if expected_size is None or dest.stat().st_size == expected_size:
            return
        dest.unlink()
    _log.info("Downloading %s → %s", url, dest)
    tmp = dest.with_suffix(dest.suffix + ".part")
    urllib.request.urlretrieve(url, tmp)  # noqa: S310 — HF over HTTPS
    if expected_size is not None and tmp.stat().st_size != expected_size:
        tmp.unlink(missing_ok=True)
        raise RuntimeError(f"size mismatch downloading {url}")
    tmp.rename(dest)


def _ensure_package(pkg: Path, base_url: str, files: Iterable[tuple[str, int]]) -> None:
    pkg.mkdir(parents=True, exist_ok=True)
    for rel, size in files:
        dest = pkg / rel
        _ensure_file(dest, f"{base_url}/{rel}", expected_size=size)
