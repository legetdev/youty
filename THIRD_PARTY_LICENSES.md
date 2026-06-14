# Third-party notices

Youty bundles or builds against the third-party software listed below.
Every entry's full license text lives at the linked path in this repo —
nothing here is summarised away.

Youty itself is MIT-licensed (see [`LICENSE`](LICENSE)).

---

## FFmpeg

- **Component:** statically-linked `libavcodec`, `libavformat`, `libavutil`,
  `libswscale` archives in `Vendor/ffmpeg/lib/`. Version 7.1.1, built from
  source via [`Scripts/build-ffmpeg.sh`](Scripts/build-ffmpeg.sh).
- **License:** GNU Lesser General Public License, version 2.1 or later
  (LGPL-2.1+). The build configuration uses LGPL-eligible decoder components
  only — no `--enable-gpl`, no `--enable-nonfree`, no GPL-only encoders
  (x264, fdk-aac, etc.).
- **License text:** [`Vendor/ffmpeg/licenses/COPYING.LGPLv2.1`](Vendor/ffmpeg/licenses/COPYING.LGPLv2.1)
  (verbatim from the FFmpeg 7.1.1 source tarball).
- **Contributors:** [`Vendor/ffmpeg/licenses/CREDITS`](Vendor/ffmpeg/licenses/CREDITS).
- **Project home:** <https://ffmpeg.org>.
- **Source for the exact build linked into Youty:**
  <https://ffmpeg.org/releases/ffmpeg-7.1.1.tar.xz> (the URL `Scripts/build-ffmpeg.sh`
  downloads at build time).

### LGPL §6 — relinking obligation

LGPL §6 requires that recipients of a binary statically-linked against an
LGPL-licensed library be able to relink the application against a modified
version of that library. Youty satisfies that obligation as follows:

1. **Youty's own source is public and MIT-licensed.** Anyone with a clone of
   this repo can rebuild the application from scratch.
2. **The FFmpeg build is fully scripted and reproducible.**
   [`Scripts/build-ffmpeg.sh`](Scripts/build-ffmpeg.sh) downloads
   FFmpeg 7.1.1 from `ffmpeg.org`, applies the exact `./configure` flags
   used by every shipped binary, and emits the static archives into
   `Vendor/ffmpeg/`. A user who wants to relink against a modified FFmpeg
   only needs to (a) edit the FFmpeg source they unpack from the tarball,
   (b) re-run the build script pointing it at their modified tree, and
   (c) re-run `xcodebuild -scheme youty -configuration Release`.
3. **The exact upstream FFmpeg version is pinned** at the top of
   `Scripts/build-ffmpeg.sh` and printed at runtime in the app's
   *About* panel (Settings → About). Replacing it is a one-line edit.

This mirrors the relink-via-source posture used by IINA, VLC's Mac builds,
and similar LGPL-FFmpeg-linking apps.

---

## sqlite-vec

- **Component:** Python dependency of the MCP server (`youty-mcp`); also
  loaded as a SQLite extension by the Mac app's indexer.
- **License:** Dual-licensed under **MIT OR Apache-2.0** — recipients
  may choose either. Verified from the project's `pyproject.toml`
  metadata.
- **Project home:** <https://github.com/asg017/sqlite-vec>.
- **Full license text:** <https://github.com/asg017/sqlite-vec/blob/main/LICENSE>
  (also reproduced in the installed wheel).

---

## SQLite

- **Component:** SQLite, used both directly (Swift) and via Python's stdlib
  in the MCP server.
- **License:** SQLite is in the public domain.
  <https://www.sqlite.org/copyright.html>.
- **Project home:** <https://www.sqlite.org>.

---

## Sparkle

- **Component:** Auto-update framework. Bundled inside the Mac app at
  `Youty.app/Contents/Frameworks/Sparkle.framework`, fetched by Swift
  Package Manager from the upstream GitHub repo at build time. Used to
  check `https://youtyapp.vercel.app/appcast.xml` for new releases and
  download + EdDSA-verify signed DMGs.
- **Version:** Pinned at 2.9.2 in
  [`Package.resolved`](youty.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved).
- **License:** MIT. The full text ships inside the framework bundle at
  `Sparkle.framework/Versions/Current/Resources/LICENSE` and is
  surfaced in the app's *About* panel.
- **Project home:** <https://sparkle-project.org>.
- **Source:** <https://github.com/sparkle-project/Sparkle>.
- **Why this is the only third-party Swift dependency:** vetted against
  the third-party checklist in `CLAUDE.md` (MIT, 20-year track record,
  EdDSA-signed updates, GitHub-sponsored maintenance, single-purpose,
  shipped in CleanShot / Bartender / iStat / Tot) and explicitly
  green-lit during R.1 decisions on 2026-05-19. Every other component
  here is either statically built from source, bundled as data, or an
  Apple-provided system framework.

---

## Google SigLIP-Base-Patch16-224 (image encoder, Core ML)

- **Component:** ML model used by the Mac app and CLI to embed video
  frames into a 768-dim joint vision-text vector space. Shipped as a
  Core ML `.mlpackage` bundled inside `Youty.app/Contents/Resources/`.
- **Source model:** `google/siglip-base-patch16-224`
  (<https://huggingface.co/google/siglip-base-patch16-224>).
- **License:** Apache License, Version 2.0. Verbatim text at
  [`Vendor/siglip/licenses/LICENSE`](Vendor/siglip/licenses/LICENSE)
  (mirrored from `google-research/big_vision`, the canonical SigLIP repo).
  Attribution + redistribution notice at
  [`Vendor/siglip/licenses/NOTICE`](Vendor/siglip/licenses/NOTICE).
- **Conversion provenance:** `Scripts/convert-siglip-coreml.py` traces the
  HuggingFace `transformers` checkpoint with PyTorch and emits a Core ML
  `.mlpackage` at fp16 precision. SigLIP's per-channel normalization is
  baked into `ct.ImageType` scale + bias at conversion time, so the
  bundled model accepts plain RGB pixels at 224×224. Cosine similarity
  vs the PyTorch reference is **0.9999** at conversion verification time
  (see `--skip-verify` flag for the cosine check).
- **Text encoder counterpart:** The Python MCP server (`youty-mcp`)
  embeds user queries using the same SigLIP model via the HuggingFace
  `transformers` library directly — see the `transformers` and `torch`
  dependencies in [`youty-mcp/pyproject.toml`](youty-mcp/pyproject.toml).
  Both sides land in the same vector space.
- **Citation:** "Sigmoid Loss for Language Image Pre-Training", Zhai et
  al., ICCV 2023 (<https://arxiv.org/abs/2303.15343>).

---

## Google EmbeddingGemma-300m (text encoder, Core ML)

- **Component:** ML model used by the Mac app and CLI to embed transcript
  text into a 768-dim vector space for AI search. This is the **default**
  text embedder (Phase S) — fully on-device, no API key, nothing leaves the
  Mac. Shipped as a Core ML `.mlpackage` bundled inside
  `Youty.app/Contents/Resources/` and installed into the CLI's shared
  resource directory by [`Scripts/install-cli.sh`](Scripts/install-cli.sh).
- **Source model:** `google/embeddinggemma-300m` (Google DeepMind)
  (<https://huggingface.co/google/embeddinggemma-300m>).
- **License:** **Gemma Terms of Use** — this is *not* an OSI open-source
  license. It permits commercial use and redistribution of the model and
  derivatives, subject to the use restrictions in the Gemma Prohibited Use
  Policy and the attribution + modification-notice requirements of §3.1.
  - Gemma Terms of Use: <https://ai.google.dev/gemma/terms>
  - Gemma Prohibited Use Policy: <https://ai.google.dev/gemma/prohibited_use_policy>
- **Required NOTICE + modification notice:** verbatim at
  [`Vendor/embeddinggemma/licenses/EmbeddingGemma-NOTICE.txt`](Vendor/embeddinggemma/licenses/EmbeddingGemma-NOTICE.txt),
  bundled into the app + CLI. It carries the mandated "Gemma is provided
  under and subject to the Gemma Terms of Use" attribution and records that
  the shipped weights are a MODIFIED (Core ML, int8-quantized) form. The
  authoritative terms are the versions Google hosts at the URLs above.
- **Conversion provenance:** [`Scripts/convert-embeddinggemma-coreml.py`](Scripts/convert-embeddinggemma-coreml.py)
  exports the sentence-transformers checkpoint via `torch.export` and emits
  a Core ML `.mlpackage` (fp32 compute, int8-quantized weights) running the
  full pipeline (Transformer → mean pool → Dense 768→3072 → Dense 3072→768
  → L2 normalize). Conversion fidelity vs the PyTorch reference: mean cosine
  **0.9997** (verified, Phase S.0).
- **Native tokenizer (no third-party dependency):** a from-scratch Swift BPE
  tokenizer ([`Sources/GemmaTokenizer.swift`](Sources/GemmaTokenizer.swift))
  reproduces Gemma's tokenizer bit-for-bit from a compact binary artifact
  (`Vendor/embeddinggemma/tokenizer/*.bin`) built by
  [`Scripts/build-gemma-tokenizer-artifact.py`](Scripts/build-gemma-tokenizer-artifact.py).
- **Text encoder counterpart:** the Python MCP server (`youty-mcp`) embeds
  user queries with the same checkpoint via `sentence-transformers`, so
  query + document vectors share one space. The model is fetched from
  HuggingFace on first use and cached locally.
- **Citation:** EmbeddingGemma, Google DeepMind, 2025.

---

## Apple system frameworks

The app links against Apple-provided system frameworks (Foundation, AppKit,
SwiftUI, WebKit, AVFoundation, CoreML, VideoToolbox, Speech, AppIntents).
These are part of the macOS SDK and are governed by the Apple SDK License
Agreement; they are neither bundled with nor redistributed by Youty.

---

## Google Gemini API

The Mac app and MCP server can *optionally* make outbound HTTPS requests
to Google's Generative Language API (`generativelanguage.googleapis.com`)
for text-search embeddings, using an API key the *user* supplies in
Settings. This is **off by default** — the default text embedder is the
on-device EmbeddingGemma model above (no key, no network). Gemini is an
opt-in upgrade for a small accuracy gain. The Gemini API and the
embeddings it returns are governed by Google's API Terms of Service:
<https://ai.google.dev/terms>.

No Google client code is bundled with Youty.

---

## Python runtime dependencies (`youty-mcp`)

The MCP server's runtime dependencies are pinned in
[`youty-mcp/pyproject.toml`](youty-mcp/pyproject.toml). Each is installed
from PyPI by `pip` / `uv` at install time, not redistributed by this repo:

| Package | License |
|---|---|
| `mcp` | MIT |
| `sqlite-vec` | MIT OR Apache-2.0 (dual) |
| `httpx` | BSD-3-Clause |
| `numpy` | `BSD-3-Clause AND 0BSD AND MIT AND Zlib AND CC0-1.0` (composite — NumPy core is BSD-3; bundled components add the others) |
| `transformers` | Apache-2.0 |
| `sentence-transformers` | Apache-2.0 |
| `torch` | BSD-3-Clause |

Each package's full license text ships with its wheel and is
viewable via `pip show -f <pkg>` after installation.
