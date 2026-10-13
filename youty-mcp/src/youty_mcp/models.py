"""Locate the on-device EmbeddingGemma 2 query model.

Search embeds each query with the same EmbeddingGemma 2 text model the Youty
app used for transcripts and frames. Most users already have it: the Mac app
and the Homebrew CLI both ship it, so the server reuses those files directly.
Only when neither is installed does it download Youty's checksummed models
asset once into `~/.cache/youty/models/<version>/`.

Required files: the Core ML text model (`EmbeddingGemma2Text.mlmodelc`, or the
`.mlpackage` source, compiled once and cached), the bf16 token table
(`EmbeddingGemma2Tokens.bf16`), and Google's `tokenizer.json`.
"""
from __future__ import annotations

import hashlib
import logging
import os
import shutil
import tarfile
import tempfile
import urllib.request
from dataclasses import dataclass
from pathlib import Path

_log = logging.getLogger(__name__)

TEXT_MODEL = "EmbeddingGemma2Text"
TOKEN_TABLE = "EmbeddingGemma2Tokens.bf16"
TOKENIZER = "tokenizer.json"

# Release asset carrying the models (the same tarball source builds fetch).
# Stamped in lockstep with Scripts/fetch-models.sh by `Scripts/release.sh --models`.
MODELS_VERSION = "2.0.0"
MODELS_SHA256 = "d0fb8541138a0460a59eb869cdc4cb13563d31fb8bc30bbd1a69793c5b3340f4"
MODELS_URL = (
    f"https://github.com/legetdev/youty/releases/download/"
    f"models-{MODELS_VERSION}/youty-models-{MODELS_VERSION}.tar.gz"
)
CACHE = Path("~/.cache/youty/models").expanduser() / MODELS_VERSION


@dataclass(frozen=True)
class Assets:
    text_model: Path   # .mlmodelc (preferred) or .mlpackage
    token_table: Path
    tokenizer: Path


def _assets_in(root: Path) -> Assets | None:
    """The three query files under `root` (searched recursively), if all exist."""
    if not root.is_dir():
        return None

    def first(*names: str) -> Path | None:
        for name in names:
            direct = root / name
            if direct.exists():
                return direct
            found = next(root.rglob(name), None)
            if found is not None:
                return found
        return None

    model = first(f"{TEXT_MODEL}.mlmodelc", f"{TEXT_MODEL}.mlpackage")
    table = first(TOKEN_TABLE)
    tokenizer = first(TOKENIZER)
    if model and table and tokenizer:
        return Assets(model, table, tokenizer)
    return None


def _installed_roots() -> list[Path]:
    """Model locations of an installed Youty app or CLI, most likely first."""
    home = Path.home()
    # The bundle ships as `youty.app`; check both spellings for case-sensitive volumes.
    roots = [base / name / "Contents/Resources"
             for base in (Path("/Applications"), home / "Applications")
             for name in ("youty.app", "Youty.app")] + [
        home / "Library/Application Support/Youty/resources",   # Scripts/install-cli.sh
        Path("/opt/homebrew/share/youty"),                        # Homebrew formula
        Path("/usr/local/share/youty"),
    ]
    cli = shutil.which("youty")
    if cli:
        roots.append(Path(cli).resolve().parent.parent / "share/youty")
    return roots


class NotReady(RuntimeError):
    """The model files still have to be downloaded or compiled."""


def locate(prepare: bool = True) -> Assets:
    """Resolve the query model files, downloading them once if needed.

    With `prepare=False` it never downloads or compiles: it raises `NotReady`
    when that work is still needed, so callers can do it in the background.
    """
    override = os.environ.get("YOUTY_MODELS_DIR")
    if override:
        assets = _assets_in(Path(override).expanduser())
        if assets is None:
            raise RuntimeError(f"YOUTY_MODELS_DIR={override} does not contain the EmbeddingGemma 2 query files")
        return _compiled(assets, prepare)
    for root in _installed_roots():
        assets = _assets_in(root)
        if assets is not None:
            return _compiled(assets, prepare)
    assets = _assets_in(CACHE)
    if assets is None:
        if not prepare:
            raise NotReady("the search model has not been downloaded yet")
        _download()
        assets = _assets_in(CACHE)
    if assets is None:
        raise RuntimeError(f"the models asset did not contain {TEXT_MODEL}, {TOKEN_TABLE}, and {TOKENIZER}")
    return _compiled(assets, prepare)


def _compiled(assets: Assets, prepare: bool = True) -> Assets:
    """Use a compiled `.mlmodelc`; compile an `.mlpackage` once into the cache."""
    if assets.text_model.suffix == ".mlmodelc":
        return assets
    source = assets.text_model.resolve()
    if CACHE.resolve() in source.parents:
        target = CACHE / f"{TEXT_MODEL}.mlmodelc"
    else:  # e.g. YOUTY_MODELS_DIR: key by source and contents' age so it is never reused stale
        newest = max(p.stat().st_mtime_ns for p in source.rglob("*") if p.is_file())
        key = hashlib.sha256(f"{source}:{newest}".encode()).hexdigest()[:16]
        target = CACHE / "compiled" / key / f"{TEXT_MODEL}.mlmodelc"
    if not target.exists():
        if not prepare:
            raise NotReady("the search model has not been compiled yet")
        import coremltools as ct

        _log.info("Compiling %s once …", assets.text_model.name)
        target.parent.mkdir(parents=True, exist_ok=True)
        compiled = Path(ct.models.utils.compile_model(str(assets.text_model)))
        staged = target.parent / f".{TEXT_MODEL}.{os.getpid()}.mlmodelc"
        shutil.move(str(compiled), staged)
        try:
            staged.rename(target)
        except OSError:  # another session finished first
            shutil.rmtree(staged, ignore_errors=True)
    return Assets(target, assets.token_table, assets.tokenizer)


def _download() -> None:
    """Fetch and verify the pinned models asset, extracting only on a match."""
    _log.info("Fetching Youty models (one time) from %s …", MODELS_URL)
    CACHE.parent.mkdir(parents=True, exist_ok=True)
    digest = hashlib.sha256()
    with tempfile.TemporaryDirectory(prefix="youty-models-") as directory:
        tarball = Path(directory) / "models.tar.gz"
        with urllib.request.urlopen(MODELS_URL, timeout=60) as response, tarball.open("wb") as out:
            while chunk := response.read(1 << 20):
                out.write(chunk)
                digest.update(chunk)
        if digest.hexdigest() != MODELS_SHA256:
            raise RuntimeError(
                "Youty models asset failed checksum verification — refusing to extract.\n"
                f"  expected {MODELS_SHA256}\n  got      {digest.hexdigest()}"
            )
        # Extract beside the cache and publish it only once complete, so an
        # interrupted extraction is never mistaken for a usable cache.
        staged = Path(tempfile.mkdtemp(prefix=".staging-", dir=CACHE.parent))
        try:
            with tarfile.open(tarball) as archive:
                archive.extractall(staged, filter="data")
            if _assets_in(staged) is None:
                raise RuntimeError("the models asset is incomplete")
            shutil.rmtree(CACHE, ignore_errors=True)
            staged.rename(CACHE)
        finally:
            shutil.rmtree(staged, ignore_errors=True)
