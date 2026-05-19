#!/usr/bin/env python3
"""End-to-end runtime verification of the Python-side SigLIP text encoder.

Loads `youty_mcp.siglip_text.SigLIPTextEncoder`, embeds a few test queries
via the real `transformers.SiglipTextModel`, and validates:
  - The transformers download + load path actually works
  - Output is a 768-dim Python list
  - L2 norm is ~1.0 (encoder normalises internally)
  - No NaN / Inf values
  - Two semantically related queries are closer in cosine than unrelated ones
    (sanity check that the embedding space is meaningful — strict numeric
     SigLIP cosines are small, so we just check ordering, not magnitude)

Run via:
    cd youty-mcp
    uv run --group dev python ../Scripts/verify-siglip-python.py

Prints PYTHON_SIGLIP_OK on success; non-zero exit otherwise.
"""

from __future__ import annotations

import math
import sys
import time

# Add the youty-mcp source to PYTHONPATH the same way pytest does, so this
# script works both from repo root and from youty-mcp/.
import pathlib
ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "youty-mcp" / "src"))

from youty_mcp.siglip_text import EMBEDDING_DIM, HF_MODEL_ID, SigLIPTextEncoder


def cosine(a: list[float], b: list[float]) -> float:
    return sum(x * y for x, y in zip(a, b))


def main() -> int:
    print(f"HF_MODEL_ID={HF_MODEL_ID}")
    print(f"EXPECTED_DIM={EMBEDDING_DIM}")

    enc = SigLIPTextEncoder()
    t0 = time.perf_counter()
    print("Loading + first-embed (downloads ~370 MB on a cold cache) ...",
          flush=True)
    vec_first = enc.embed_text("a snowy mountain")
    load_ms = int((time.perf_counter() - t0) * 1000)
    print(f"FIRST_EMBED_MS={load_ms}")

    # Validate first vector.
    if len(vec_first) != EMBEDDING_DIM:
        print(f"ERROR=dim_mismatch got={len(vec_first)} expected={EMBEDDING_DIM}",
              file=sys.stderr)
        return 1

    norm = math.sqrt(sum(x * x for x in vec_first))
    print(f"L2_NORM={norm:.4f}")
    if not (0.9 < norm < 1.1):
        print(f"ERROR=unexpected_norm {norm}", file=sys.stderr)
        return 1

    if any(not math.isfinite(x) for x in vec_first):
        print("ERROR=non_finite_value", file=sys.stderr)
        return 1

    # Sanity: hot embed (cache warm) should be ~50-100ms.
    t1 = time.perf_counter()
    vec_again = enc.embed_text("a snowy mountain")
    hot_ms = int((time.perf_counter() - t1) * 1000)
    print(f"HOT_EMBED_MS={hot_ms}")

    # Determinism: the exact same input should produce the exact same output
    # (up to floating-point noise within fp32). Off-by-one mismatches are
    # usually a dropout / no-grad bug.
    delta = max(abs(a - b) for a, b in zip(vec_first, vec_again))
    print(f"MAX_DELTA_SAME_INPUT={delta:.2e}")
    if delta > 1e-3:
        print(f"ERROR=non_deterministic_output max_delta={delta}",
              file=sys.stderr)
        return 1

    # Semantic ordering. Three queries: two visually similar (snowy mountain
    # ↔ ski slope), one unrelated (database server). Expectation:
    #   cos(snow1, snow2) > cos(snow1, server)
    snow1 = vec_first
    snow2 = enc.embed_text("ski slope in winter")
    server = enc.embed_text("rack-mounted database server")
    c_match = cosine(snow1, snow2)
    c_miss = cosine(snow1, server)
    print(f"COS_SNOW1_SNOW2={c_match:.4f}")
    print(f"COS_SNOW1_SERVER={c_miss:.4f}")
    if not (c_match > c_miss):
        print(f"ERROR=semantic_order match={c_match} > miss={c_miss}",
              file=sys.stderr)
        return 1

    print("PYTHON_SIGLIP_OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
