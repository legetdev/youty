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

## Apple system frameworks

The app links against Apple-provided system frameworks (Foundation, AppKit,
SwiftUI, WebKit, AVFoundation, CoreML, VideoToolbox, Speech, AppIntents).
These are part of the macOS SDK and are governed by the Apple SDK License
Agreement; they are neither bundled with nor redistributed by Youty.

---

## Google Gemini API

The Mac app and MCP server make optional outbound HTTPS requests to
Google's Generative Language API (`generativelanguage.googleapis.com`)
using an API key the *user* supplies in Settings. The Gemini API and the
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
| `torch` | BSD-3-Clause |

Each package's full license text ships with its wheel and is
viewable via `pip show -f <pkg>` after installation.
