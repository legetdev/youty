#!/usr/bin/env -S uv run --script

# /// script
# requires-python = ">=3.10,<3.13"
# dependencies = [
#   "coremltools>=8.1",
#   "transformers>=4.56",
#   "sentence-transformers>=5.0",
#   "torch>=2.4",
#   "numpy<2",
# ]
# ///

"""Phase S.0 — convert Google EmbeddingGemma's text encoder to a Core ML .mlpackage.

Mirrors Scripts/convert-siglip-coreml.py. This is the on-device replacement for
the Gemini text embedder: the Swift indexer (Mac app + CLI) will embed transcript
chunks locally; the Python MCP embeds queries with the same checkpoint, so docs +
queries share one space.

Source model: google/embeddinggemma-300m (gated — accept the Gemma license on
HuggingFace and `huggingface-cli login` before running; see the run notes below).
Output:       Vendor/embeddinggemma/models/EmbeddingGemma-300m_text.mlpackage

EmbeddingGemma specifics (confirmed on the first real run, then locked here):
  - Pooling is MEAN over the last hidden state, then L2-normalize.
  - Retrieval uses task prompts ("task: search result | query: " for queries,
    "title: none | text: " for documents) applied at TOKENIZATION time — they are
    NOT part of the Core ML graph. The Swift/MCP callers prepend them.
  - Native embedding dim is 768 (Matryoshka-truncatable) — matches Youty's index.

This script is the S.0 gate's conversion half. The retrieval-quality half lives in
Scripts/embeddinggemma-quality-check.py (compares EmbeddingGemma vs Gemini on a real
vault sample). Neither can run until the gated model is accessible.

Run from repo root (after the one-time HF unblock):
    Scripts/convert-embeddinggemma-coreml.py [--seq-len 256]
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np
import torch

import coremltools as ct
from sentence_transformers import SentenceTransformer


HF_MODEL_ID = "google/embeddinggemma-300m"
EMBED_DIM = 768
DEFAULT_SEQ_LEN = 256  # transcript chunks are short; EmbeddingGemma supports up to 2048


class TextEncoderWrapper(torch.nn.Module):
    """Exposes the mean-pooled, L2-normalized sentence embedding as a plain tensor
    so the Core ML graph outputs a vector, not a HF ModelOutput dict. Tokenization
    + task prompts happen outside this graph (in the Swift/MCP callers)."""

    def __init__(self, st_model: SentenceTransformer):
        super().__init__()
        self.transformer = st_model[0].auto_model  # Gemma3TextModel

    def forward(self, input_ids: torch.Tensor, attention_mask: torch.Tensor) -> torch.Tensor:
        out = self.transformer(input_ids=input_ids, attention_mask=attention_mask)
        hidden = out.last_hidden_state                      # [B, T, H]
        mask = attention_mask.unsqueeze(-1).to(hidden.dtype)
        summed = (hidden * mask).sum(dim=1)
        counts = mask.sum(dim=1).clamp(min=1e-9)
        mean = summed / counts
        return mean / mean.norm(dim=-1, keepdim=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output", "-o",
        type=Path,
        default=Path(__file__).resolve().parent.parent / "Vendor/embeddinggemma/models",
    )
    parser.add_argument("--seq-len", type=int, default=DEFAULT_SEQ_LEN)
    parser.add_argument("--skip-verify", action="store_true")
    args = parser.parse_args()

    out_dir: Path = args.output
    out_dir.mkdir(parents=True, exist_ok=True)
    pkg_path = out_dir / "EmbeddingGemma-300m_text.mlpackage"

    print(f"→ Loading {HF_MODEL_ID} (gated — requires HF login) ...", flush=True)
    # Force CPU (coremltools traces the CPU graph) + eager attention so the
    # model avoids transformers' vmap-based mask construction, which the legacy
    # torch.jit.trace path cannot capture (RuntimeError: unordered_map::at).
    st = SentenceTransformer(
        HF_MODEL_ID, device="cpu",
        model_kwargs={"attn_implementation": "eager"},
    ).eval()
    tokenizer = st.tokenizer

    wrapper = TextEncoderWrapper(st).eval()

    # Modern Gemma-3 masking uses torch.vmap, which the legacy torch.jit.trace
    # cannot capture. torch.export (Dynamo-based) is the path coremltools
    # recommends for current transformer models. Fixed seq length keeps the
    # exported program simple; callers pad/truncate to `seq`.
    seq = args.seq_len
    example_ids = torch.ones(1, seq, dtype=torch.long)
    example_mask = torch.ones(1, seq, dtype=torch.long)
    print("→ Exporting (torch.export) ...", flush=True)
    with torch.no_grad():
        exported = torch.export.export(wrapper, (example_ids, example_mask))
        # coremltools accepts the ATEN/EDGE dialect, not TRAINING — lower it.
        exported = exported.run_decompositions({})

    print("→ Converting to Core ML (ML Program, fp16) ...", flush=True)
    mlmodel = ct.convert(
        exported,
        outputs=[ct.TensorType(name="embedding")],
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS15,
    )

    mlmodel.short_description = (
        "EmbeddingGemma-300m text encoder (Google, Gemma Terms). "
        "Mean-pooled, L2-normalized 768-dim embedding. Task prompts applied by caller."
    )
    mlmodel.author = f"{HF_MODEL_ID} via Scripts/convert-embeddinggemma-coreml.py"
    mlmodel.license = "Gemma Terms of Use"

    if pkg_path.exists():
        import shutil
        shutil.rmtree(pkg_path)
    print(f"→ Saving {pkg_path} ...", flush=True)
    mlmodel.save(str(pkg_path))

    # Smoke-test: a sample document, CoreML vs sentence-transformers reference.
    if not args.skip_verify:
        print("→ Verifying CoreML vs PyTorch cosine ...", flush=True)
        sample = "title: none | text: A short clip explaining how to use AI for video."
        enc = tokenizer(sample, return_tensors="pt", padding="max_length",
                        truncation=True, max_length=seq)
        with torch.no_grad():
            pt = wrapper(enc["input_ids"].to(torch.int32),
                         enc["attention_mask"].to(torch.int32)).numpy().reshape(-1)
        cm_out = mlmodel.predict({
            "input_ids": enc["input_ids"].to(torch.int32).numpy(),
            "attention_mask": enc["attention_mask"].to(torch.int32).numpy(),
        })
        cm = np.asarray(list(cm_out.values())[0], dtype=np.float32).reshape(-1)
        cm = cm / (np.linalg.norm(cm) + 1e-9)
        pt = pt / (np.linalg.norm(pt) + 1e-9)
        cos = float(np.dot(pt, cm))
        print(f"  cosine(PyTorch, CoreML) = {cos:.4f}", flush=True)
        if cos < 0.99:
            print("  WARNING: cosine below 0.99 — investigate pooling/precision before shipping.",
                  file=sys.stderr, flush=True)
            return 2

    size_mb = sum(p.stat().st_size for p in pkg_path.rglob("*") if p.is_file()) / (1024 * 1024)
    print(f"→ Done. {pkg_path} = {size_mb:.1f} MB", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
