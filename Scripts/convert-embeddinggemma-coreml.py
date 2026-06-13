#!/usr/bin/env -S uv run --script

# /// script
# requires-python = ">=3.10,<3.13"
# dependencies = [
#   "coremltools>=8.1,<9",
#   "transformers>=4.56",
#   "sentence-transformers>=5.0",
#   "torch>=2.12",
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

# --- coremltools op-coverage shims for the torch.export (exir) frontend ---
# Gemma-3's exported graph uses a few ops the exir frontend doesn't translate
# yet. Each shim maps one to an equivalent MIL op. Fidelity is guarded by the
# cosine check at the end, so a wrong shim shows up immediately.
from coremltools.converters.mil.frontend.torch.torch_op_registry import register_torch_op
from coremltools.converters.mil.frontend.torch.ops import _get_inputs
from coremltools.converters.mil.mil import Builder as mb


@register_torch_op
def new_ones(context, node):
    # aten.new_ones(self, size, ...) here builds the all-ones padding mask, which
    # downstream mask ops treat as bool — emit bool so dtypes stay consistent.
    inputs = _get_inputs(context, node)
    size = inputs[1]
    res = mb.fill(shape=size, value=1.0)
    res = mb.cast(x=res, dtype="bool", name=node.name)
    context.add(res)


# torch.export inserts runtime assertions (no compute, no outputs) — no-op them.
@register_torch_op(
    torch_alias=[
        "_assert_tensor_metadata",
        "_assert_scalar",
        "_assert_async",
        "sym_constrain_range",
        "sym_constrain_range_for_size",
    ],
    override=True,
)
def _noop_assert(context, node):
    return


# Boolean attention masks combine via bitwise | — equivalent to logical_or.
# (bitwise_and is already covered by coremltools.)
@register_torch_op
def bitwise_or(context, node):
    a, b = _get_inputs(context, node, expected=2)
    # Operands are boolean masks; coremltools requires matching dtypes, and the
    # new_ones shim emits fp — cast both to bool so it's a true logical-or.
    a = mb.cast(x=a, dtype="bool")
    b = mb.cast(x=b, dtype="bool")
    context.add(mb.logical_or(x=a, y=b, name=node.name))


# where(cond, tensor, scalar_other) — the one where-variant the frontend misses.
@register_torch_op(torch_alias=["where.scalarother"])
def _where_scalarother(context, node):
    cond, a, b = _get_inputs(context, node, expected=3)
    context.add(mb.select(cond=cond, a=a, b=b, name=node.name))


HF_MODEL_ID = "google/embeddinggemma-300m"
EMBED_DIM = 768
DEFAULT_SEQ_LEN = 256  # transcript chunks are short; EmbeddingGemma supports up to 2048


class TextEncoderWrapper(torch.nn.Module):
    """Runs EmbeddingGemma's FULL sentence-transformers pipeline and returns the
    final L2-normalized embedding as a plain tensor (so the Core ML graph outputs
    a vector, not a dict). The pipeline is Transformer -> Pooling(mean) ->
    Dense(768->3072) -> Dense(3072->768) -> Normalize; skipping the Dense heads
    silently degrades retrieval, so we run every module. Tokenization + task
    prompts happen outside this graph (in the Swift/MCP callers)."""

    def __init__(self, st_model: SentenceTransformer):
        super().__init__()
        self.modules_list = torch.nn.ModuleList(list(st_model.children()))

    def forward(self, input_ids: torch.Tensor, attention_mask: torch.Tensor) -> torch.Tensor:
        feats = {"input_ids": input_ids, "attention_mask": attention_mask}
        for module in self.modules_list:
            feats = module(feats)
        return feats["sentence_embedding"]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output", "-o",
        type=Path,
        default=Path(__file__).resolve().parent.parent / "Vendor/embeddinggemma/models",
    )
    parser.add_argument("--seq-len", type=int, default=DEFAULT_SEQ_LEN)
    # Verified shipping recipe: fp32 compute + int8 weights -> cosine 0.9997 vs
    # PyTorch at 296 MB (fp16 alone only reaches 0.9927). See S.0 notes.
    parser.add_argument("--precision", choices=["fp16", "fp32"], default="fp32")
    parser.add_argument("--quantize", choices=["none", "int8"], default="int8")
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
    precision = {"fp16": ct.precision.FLOAT16, "fp32": ct.precision.FLOAT32}[args.precision]
    mlmodel = ct.convert(
        exported,
        outputs=[ct.TensorType(name="embedding")],
        compute_precision=precision,
        minimum_deployment_target=ct.target.macOS15,
    )

    # Optional int8 weight quantization: ~4x smaller than fp32 with compute kept
    # faithful, so fidelity stays far above naive fp16. The right size/quality
    # balance for shipping a 308M model on-device.
    if args.quantize == "int8":
        import coremltools.optimize.coreml as cto
        print("→ Quantizing weights to int8 ...", flush=True)
        cfg = cto.OptimizationConfig(
            global_config=cto.OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int8")
        )
        mlmodel = cto.linear_quantize_weights(mlmodel, cfg)

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
