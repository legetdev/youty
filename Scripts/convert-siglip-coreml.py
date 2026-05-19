#!/usr/bin/env -S uv run --script

# /// script
# requires-python = ">=3.10,<3.13"
# dependencies = [
#   "coremltools>=8.0",
#   "transformers>=4.40,<5",
#   "torch>=2.0,<3",
#   "pillow",
#   "numpy<2",
# ]
# ///

"""Convert Google SigLIP-Base-Patch16-224's image encoder to a Core ML .mlpackage.

Why only the image encoder: Youty's Swift side (Mac app + CLI) embeds frames
locally. The text-query side runs in the Python MCP server, which can use
PyTorch via `transformers` directly — no CoreML conversion needed for text.

The .mlpackage emitted here is intended to be bundled in the Mac app under
`Vendor/siglip/models/`. Apple Silicon (ANE) inference for the embedded
image encoder targets ~3-5 ms per frame.

Source model: google/siglip-base-patch16-224 (Apache-2.0).
Output:       Vendor/siglip/models/SigLIP-Base-224_image.mlpackage

Run from repo root:
    Scripts/convert-siglip-coreml.py
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np
import torch
from PIL import Image
from transformers import SiglipVisionModel, SiglipImageProcessor

import coremltools as ct


HF_MODEL_ID = "google/siglip-base-patch16-224"
IMAGE_SIZE = 224
EMBED_DIM = 768  # SigLIP-Base hidden size + projection dim


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output", "-o",
        type=Path,
        default=Path(__file__).resolve().parent.parent / "Vendor/siglip/models",
    )
    parser.add_argument("--skip-verify", action="store_true")
    args = parser.parse_args()

    out_dir: Path = args.output
    out_dir.mkdir(parents=True, exist_ok=True)
    pkg_path = out_dir / "SigLIP-Base-224_image.mlpackage"

    print(f"→ Loading {HF_MODEL_ID} ...", flush=True)
    vision = SiglipVisionModel.from_pretrained(HF_MODEL_ID).eval()
    processor = SiglipImageProcessor.from_pretrained(HF_MODEL_ID)

    # SigLIP normalization params (mean=0.5, std=0.5 per channel).
    image_mean = list(processor.image_mean)
    image_std = list(processor.image_std)
    print(f"  image mean={image_mean}  std={image_std}", flush=True)

    # Wrap so the CoreML graph exposes `pooled_output` (the L2-normalised
    # image embedding) as a plain tensor, not a HF ModelOutput dict.
    class VisionTowerWrapper(torch.nn.Module):
        def __init__(self, base: SiglipVisionModel):
            super().__init__()
            self.base = base

        def forward(self, pixel_values: torch.Tensor) -> torch.Tensor:
            out = self.base(pixel_values=pixel_values)
            # `pooler_output` is the post-attention-pool feature SigLIP uses
            # as the image embedding before contrastive-loss projection.
            feats = out.pooler_output
            return feats / feats.norm(dim=-1, keepdim=True)

    wrapper = VisionTowerWrapper(vision).eval()

    # Trace.
    example = torch.randn(1, 3, IMAGE_SIZE, IMAGE_SIZE)
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, example, strict=False)

    # Convert. ImageType lets the caller pass a CGImage / PIL.Image directly
    # — CoreML will do the resize + normalize on the GPU side.
    # Normalize math: normalized = (pixel/255 - mean) / std
    #              =  pixel * (1 / (255 * std)) + (-mean / std)
    scale = 1.0 / (255.0 * image_std[0])   # SigLIP uses same std for all channels
    bias = [-m / s for m, s in zip(image_mean, image_std)]
    print(f"  ct.ImageType scale={scale:.6f}  bias={bias}", flush=True)

    print("→ Converting to Core ML (ML Program, fp16) ...", flush=True)
    mlmodel = ct.convert(
        traced,
        inputs=[ct.ImageType(
            name="image",
            shape=(1, 3, IMAGE_SIZE, IMAGE_SIZE),
            scale=scale,
            bias=bias,
            color_layout=ct.colorlayout.RGB,
        )],
        outputs=[ct.TensorType(name="embedding")],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS14,
    )

    mlmodel.short_description = (
        "SigLIP-Base-Patch16-224 image encoder (Google, Apache-2.0). "
        "Output: 768-dim L2-normalized embedding."
    )
    mlmodel.author = "google/siglip-base-patch16-224 via Scripts/convert-siglip-coreml.py"
    mlmodel.license = "Apache-2.0"

    if pkg_path.exists():
        import shutil
        shutil.rmtree(pkg_path)
    print(f"→ Saving {pkg_path} ...", flush=True)
    mlmodel.save(str(pkg_path))

    # Smoke-test: random image, compare CoreML vs PyTorch.
    if not args.skip_verify:
        print("→ Verifying CoreML vs PyTorch cosine ...", flush=True)
        img = Image.new("RGB", (IMAGE_SIZE, IMAGE_SIZE), color=(128, 64, 200))
        # PyTorch baseline.
        inputs = processor(images=img, return_tensors="pt")
        with torch.no_grad():
            pt_emb = wrapper(inputs["pixel_values"]).numpy().reshape(-1)
        # CoreML.
        cm_out = mlmodel.predict({"image": img})
        cm_emb = np.asarray(list(cm_out.values())[0], dtype=np.float32).reshape(-1)
        cm_emb = cm_emb / (np.linalg.norm(cm_emb) + 1e-9)
        pt_emb = pt_emb / (np.linalg.norm(pt_emb) + 1e-9)
        cos = float(np.dot(pt_emb, cm_emb))
        print(f"  cosine(PyTorch, CoreML) = {cos:.4f}", flush=True)
        if cos < 0.95:
            print(f"  WARNING: cosine below 0.95 — investigate before shipping.",
                  file=sys.stderr, flush=True)
            return 2

    size_mb = sum(p.stat().st_size for p in pkg_path.rglob("*") if p.is_file()) / (1024 * 1024)
    print(f"→ Done. {pkg_path} = {size_mb:.1f} MB", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
