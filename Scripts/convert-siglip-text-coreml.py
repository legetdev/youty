#!/usr/bin/env -S uv run --script

# /// script
# requires-python = ">=3.10,<3.13"
# dependencies = [
#   "coremltools>=8.0",
#   "transformers>=4.40,<5",
#   "torch>=2.0,<3",
#   "numpy<2",
#   "sentencepiece>=0.2,<1",
#   "protobuf>=4,<7",
# ]
# ///

"""Convert SigLIP-Base-Patch16-224's TEXT encoder to a Core ML .mlpackage.

Mirrors Scripts/convert-siglip-coreml.py (image encoder). This is T.1b: it lets
the MCP embed frame-search queries on-device via Core ML instead of bundling
torch + transformers. Tokenization (SentencePiece) stays in Python.

Source: google/siglip-base-patch16-224 (Apache-2.0).
Output: <--output>/SigLIP-Base-224_text.mlpackage  (default: a temp dir)

The text tower uses a fixed 64-token context (SigLIP's training length).
Verifies CoreML output vs the PyTorch reference (the exact path siglip_text.py
uses today) before declaring success.
"""
from __future__ import annotations
import argparse, sys
from pathlib import Path
import numpy as np
import torch
from transformers import AutoTokenizer, SiglipTextModel
import coremltools as ct

HF_MODEL_ID = "google/siglip-base-patch16-224"
SEQ = 64
EMBED_DIM = 768


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--output", "-o", type=Path,
                    default=Path(__file__).resolve().parent.parent / "Vendor/siglip/models")
    args = ap.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    pkg = args.output / "SigLIP-Base-224_text.mlpackage"

    print(f"→ Loading {HF_MODEL_ID} text tower ...", flush=True)
    tok = AutoTokenizer.from_pretrained(HF_MODEL_ID)
    model = SiglipTextModel.from_pretrained(HF_MODEL_ID).eval()

    # Wrap so the graph exposes the L2-normalised pooled text embedding directly.
    class TextTower(torch.nn.Module):
        def __init__(self, base): super().__init__(); self.base = base
        def forward(self, input_ids):
            feats = self.base(input_ids=input_ids).pooler_output
            return feats / feats.norm(dim=-1, keepdim=True)
    wrapper = TextTower(model).eval()

    # Example input_ids for tracing (fixed 64-token, padded).
    enc = tok("a sample query", return_tensors="pt", padding="max_length",
              truncation=True, max_length=SEQ)
    example = enc["input_ids"].to(torch.int32)
    print(f"  traced input shape={tuple(example.shape)} dtype={example.dtype}", flush=True)
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, example, strict=False)

    print("→ Converting to Core ML (ML Program, fp16) ...", flush=True)
    ml = ct.convert(
        traced,
        inputs=[ct.TensorType(name="input_ids", shape=(1, SEQ), dtype=np.int32)],
        outputs=[ct.TensorType(name="embedding")],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS14,
    )
    ml.short_description = ("SigLIP-Base-Patch16-224 text encoder (Google, Apache-2.0). "
                            "Output: 768-d L2-normalized query embedding.")
    ml.author = "google/siglip-base-patch16-224 via Scripts/convert-siglip-text-coreml.py"
    ml.license = "Apache-2.0"
    if pkg.exists():
        import shutil; shutil.rmtree(pkg)
    ml.save(str(pkg))
    print(f"→ Saved {pkg}", flush=True)

    # ---- Verify: CoreML vs the exact PyTorch reference siglip_text.py uses ----
    # CPU compute for CoreML to match the precision regime we rely on.
    cml = ct.models.MLModel(str(pkg), compute_units=ct.ComputeUnit.CPU_ONLY)
    queries = ["ai influencers", "how to grow on tiktok", "neural networks explained",
               "cooking pasta", "machine learning research", "字幕 テスト"]
    worst = 2.0
    for q in queries:
        ids = tok(q, return_tensors="pt", padding="max_length", truncation=True,
                  max_length=SEQ)["input_ids"].to(torch.int32)
        with torch.no_grad():
            pt = wrapper(ids).numpy().reshape(-1)
        cm = np.array(cml.predict({"input_ids": ids.numpy()})["embedding"],
                      np.float32).reshape(-1)
        cos = float(np.dot(pt, cm) / (np.linalg.norm(pt) * np.linalg.norm(cm) + 1e-9))
        worst = min(worst, cos)
        print(f"  '{q[:28]:<28}' CoreML↔PyTorch cosine={cos:.6f}")
    print(f"\nWORST CoreML↔PyTorch cosine = {worst:.6f} -> "
          f"{'PASS (>=0.999)' if worst >= 0.999 else 'FAIL'}")
    return 0 if worst >= 0.999 else 1


if __name__ == "__main__":
    sys.exit(main())
