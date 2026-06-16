"""On-device Core ML model resolution for the MCP query encoders.

The MCP embeds search queries with the *same* Core ML models the Mac app/CLI
use for documents — EmbeddingGemma (text) + SigLIP-Base text tower — so query
and document vectors share one space. Inference is CPU-only via `coremltools`
to match the int8-quantized indexer (GPU/ANE would drag cosine to ~0.9).

No PyTorch, no ~1.6 GB HuggingFace model download: the models come from Youty's
own release asset (a few hundred MB of Core ML), cached once under
`~/.cache/youty/`. Tokenization stays with the proven HF tokenizers.
"""
from __future__ import annotations

import logging
import os
import tarfile
import tempfile
from pathlib import Path

_log = logging.getLogger(__name__)

GEMMA_TEXT = "EmbeddingGemma-300m_text.mlpackage"
SIGLIP_TEXT = "SigLIP-Base-224_text.mlpackage"

# Release asset carrying the Core ML models (the same self-contained tarball the
# source build fetches — it includes each .mlpackage's Manifest.json so a package
# with no git checkout, like this one, can reassemble loadable models).
# MODELS_VERSION + MODELS_SHA256 are stamped in lockstep with Scripts/fetch-models.sh
# by `Scripts/release.sh --models` whenever the asset is rebuilt.
MODELS_VERSION = "1.0.0"
MODELS_SHA256 = "c3139d78af916c3a77ab57986b9729b26d243a1544b2555011b1d59c2560b6d7"
MODELS_URL = (
    f"https://github.com/legetdev/youty/releases/download/"
    f"v{MODELS_VERSION}/youty-models-{MODELS_VERSION}.tar.gz"
)
_CACHE = Path(os.path.expanduser("~/.cache/youty/coreml-models")) / MODELS_VERSION

_loaded: dict[str, object] = {}


def _find(base: Path, name: str) -> Path | None:
    if not base.exists():
        return None
    for p in base.rglob(name):
        return p
    return None


def _models_base() -> Path:
    """Directory containing (somewhere under it) the Core ML .mlpackages."""
    # 1. Explicit override — used in dev/CI to point at the repo's Vendor/ tree.
    env = os.environ.get("YOUTY_COREML_MODELS_DIR")
    if env:
        return Path(env).expanduser()
    # 2. Already downloaded + extracted.
    if _find(_CACHE, GEMMA_TEXT):
        return _CACHE
    # 3. Download the release models asset once.
    _download_models()
    return _CACHE


def _download_models() -> None:
    import hashlib
    import httpx  # already a dependency

    _CACHE.mkdir(parents=True, exist_ok=True)
    _log.info("Fetching Youty Core ML models (one-time) from %s …", MODELS_URL)
    digest = hashlib.sha256()
    with tempfile.NamedTemporaryFile(suffix=".tar.gz", delete=False) as tmp:
        with httpx.stream("GET", MODELS_URL, follow_redirects=True, timeout=None) as r:
            r.raise_for_status()
            for chunk in r.iter_bytes():
                tmp.write(chunk)
                digest.update(chunk)
        tarball = tmp.name
    try:
        # Defense-in-depth over TLS: verify the asset's SHA-256 before extracting,
        # so a truncated, corrupted, or tampered download is rejected — never trusted.
        actual = digest.hexdigest()
        if actual != MODELS_SHA256:
            raise RuntimeError(
                "Youty models asset failed checksum verification — refusing to "
                f"extract.\n  expected {MODELS_SHA256}\n  got      {actual}"
            )
        with tarfile.open(tarball) as tf:
            tf.extractall(_CACHE)  # noqa: S202 — SHA-256-verified, our own release asset
    finally:
        os.unlink(tarball)
    if not _find(_CACHE, GEMMA_TEXT):
        raise RuntimeError(
            f"models asset did not contain {GEMMA_TEXT}; "
            f"set YOUTY_COREML_MODELS_DIR to a directory holding the .mlpackages."
        )


def load(name: str):
    """Load (and memoize) a Core ML model by .mlpackage name, CPU-only."""
    if name in _loaded:
        return _loaded[name]
    import coremltools as ct

    base = _models_base()
    path = _find(base, name)
    if path is None:
        hint = (
            " — the models asset may predate this encoder; rebuild it with "
            "`Scripts/release.sh --models`."
            if name == SIGLIP_TEXT
            else ""
        )
        raise RuntimeError(
            f"Core ML model '{name}' not found under {base}. "
            f"Set YOUTY_COREML_MODELS_DIR or check the release models asset.{hint}"
        )
    _log.info("Loading Core ML model %s (CPU) …", path.name)
    model = ct.models.MLModel(str(path), compute_units=ct.ComputeUnit.CPU_ONLY)
    _loaded[name] = model
    return model
