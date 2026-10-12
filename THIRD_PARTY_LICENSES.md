# Third-party notices

Youty bundles or builds against the third-party software listed below.
Entries link to full license texts in the repository, installed packages,
or their upstream sources.

Youty itself is MIT-licensed (see [`LICENSE`](LICENSE)).

---

## FFmpeg

- **Component:** statically-linked `libavcodec`, `libavformat`, `libavutil`,
  `libswscale` archives in `Vendor/ffmpeg/lib/`. Version 9.0.2, built from
  source via [`Scripts/build-ffmpeg.sh`](Scripts/build-ffmpeg.sh).
- **License:** GNU Lesser General Public License, version 2.1 or later
  (LGPL-2.1+). The build configuration uses LGPL-eligible decoder components
  only — no `--enable-gpl`, no `--enable-nonfree`, no GPL-only encoders
  (x264, fdk-aac, etc.).
- **License text:** [`Vendor/ffmpeg/licenses/COPYING.LGPLv2.1`](Vendor/ffmpeg/licenses/COPYING.LGPLv2.1)
  (verbatim from the FFmpeg 9.0.2 source tarball).
- **Contributors:** [`Vendor/ffmpeg/licenses/CREDITS`](Vendor/ffmpeg/licenses/CREDITS).
- **Project home:** <https://ffmpeg.org>.
- **Source for the exact build linked into Youty:**
  <https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz> (the URL `Scripts/build-ffmpeg.sh`
  downloads at build time).

### LGPL §6 — relinking obligation

LGPL §6 requires that recipients of a binary statically-linked against an
LGPL-licensed library be able to relink the application against a modified
version of that library. Youty satisfies that obligation as follows:

1. **Youty's own source is public and MIT-licensed.** Anyone with a clone of
   this repo can rebuild the application from scratch.
2. **The FFmpeg build is fully scripted and reproducible.**
   [`Scripts/build-ffmpeg.sh`](Scripts/build-ffmpeg.sh) downloads
   FFmpeg 9.0.2 from `ffmpeg.org`, applies the exact `./configure` flags
   used by every shipped binary, and emits the static archives into
   `Vendor/ffmpeg/`. A user who wants to relink against a modified FFmpeg
   can unpack and modify that source, run the script's `./configure`, `make`,
   and copy steps against the modified tree, then rebuild Youty with
   `xcodebuild -scheme youty -configuration Release build`. The script itself
   always downloads a fresh upstream tree; it does not accept a source-directory
   argument.
3. **The exact upstream FFmpeg version is pinned** at the top of
   `Scripts/build-ffmpeg.sh` and printed at runtime in the app's
   *About* panel (Settings → About). Replacing it is a one-line edit.

This mirrors the relink-via-source posture used by IINA, VLC's Mac builds,
and similar LGPL-FFmpeg-linking apps.

---

## sqlite-vec

- **Component:** Python dependency of the MCP server (`youty-mcp`), which loads
  it as a SQLite extension. The Mac app writes ordinary SQLite tables without
  loading this extension.
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
- **Version:** Pinned at [2.10.0](https://github.com/sparkle-project/Sparkle/releases/tag/2.10.0) in
  [`Package.resolved`](youty.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved).
- **License:** MIT. The full text ships inside the framework bundle at
  `Sparkle.framework/Versions/Current/Resources/LICENSE` and is
  surfaced in the app's *About* panel.
- **Project home:** <https://sparkle-project.org>.
- **Source:** <https://github.com/sparkle-project/Sparkle>.
- **Why this is the only third-party Swift dependency:** vetted against
  the project's third-party checklist (MIT, 20-year track record,
  EdDSA-signed updates, GitHub-sponsored maintenance, single-purpose,
  shipped in CleanShot / Bartender / iStat / Tot) and explicitly
  green-lit on 2026-05-19. Every other component
  here is either statically built from source, bundled as data, or an
  Apple-provided system framework.

---

## Google EmbeddingGemma 2 (text and vision encoders, Core ML)

- **Component:** the on-device embedding model the Mac app and CLI use to
  place transcript text, on-screen text, and video frames in one 768-dim
  search space, and that the MCP server uses to embed search queries. Fully
  on-device; no API key; nothing leaves the Mac. Shipped as two Core ML
  packages (text, vision) plus a bf16 token table and a position table inside
  `Youty.app/Contents/Resources/`, and installed into the CLI's shared
  resource directory by the Homebrew formula and
  [`Scripts/install-cli.sh`](Scripts/install-cli.sh). The audio encoder is
  not included.
- **Source model:** `google/embeddinggemma-2` (Google DeepMind), revision
  `914f7f89142e33e77833254d9c9b90c3cef7303b`
  (<https://huggingface.co/google/embeddinggemma-2>).
- **License:** Apache License, Version 2.0. Verbatim text at
  [`Vendor/embeddinggemma2/licenses/EmbeddingGemma2-LICENSE.txt`](Vendor/embeddinggemma2/licenses/EmbeddingGemma2-LICENSE.txt);
  attribution, conversion provenance, and weight checksums at
  [`Vendor/embeddinggemma2/licenses/EmbeddingGemma2-NOTICE.txt`](Vendor/embeddinggemma2/licenses/EmbeddingGemma2-NOTICE.txt).
  Both ship in the app and CLI.
- **Core ML conversion:** the Apache-2.0 conversion published by
  FluidInference (`FluidInference/embeddinggemma-2-coreml`, revision
  `3f978ddf92cac9aa07eb2dcf6eb36cf450f3dba4`), shipped unmodified. Before
  adoption it was checked against Google's sentence-transformers reference
  (float32) on vault text and frames:
  [`Scripts/verify-embeddinggemma2.py`](Scripts/verify-embeddinggemma2.py)
  produces reference vectors and the app's `--embeddinggemma2-probe` compares
  them (text cosine ≥ 0.9999, frames ≥ 0.995, identical token ids).
- **Native tokenizer (no third-party dependency):** a from-scratch Swift BPE
  tokenizer ([`Sources/GemmaTokenizer.swift`](Sources/GemmaTokenizer.swift))
  reproduces Gemma's tokenizer from compact binary artifacts built from
  Google's `tokenizer.json` by
  [`Scripts/build-gemma-tokenizer-artifact.py`](Scripts/build-gemma-tokenizer-artifact.py).
  The MCP server reads the same `tokenizer.json` with the `tokenizers` engine.
- **Citation:** EmbeddingGemma 2, Google DeepMind, 2026.

---

## Apple system frameworks

The app links against Apple-provided system frameworks (Foundation, AppKit,
SwiftUI, WebKit, AVFoundation, CoreML, VideoToolbox, Speech, AppIntents).
These are part of the macOS SDK and are governed by the Apple SDK License
Agreement; they are neither bundled with nor redistributed by Youty.

---

## Python runtime dependencies (`youty-mcp`)

The MCP server's runtime dependency bounds are declared in
[`youty-mcp/pyproject.toml`](youty-mcp/pyproject.toml), with exact development
resolutions in [`youty-mcp/uv.lock`](youty-mcp/uv.lock). Each is installed
from PyPI by `uv` / `pip` at install time, not redistributed by this repo:

| Package | License |
|---|---|
| `mcp` | MIT |
| `sqlite-vec` | MIT OR Apache-2.0 (dual) |
| `numpy` | `BSD-3-Clause AND 0BSD AND MIT AND Zlib AND CC0-1.0` (composite — NumPy core is BSD-3; bundled components add the others) |
| `coremltools` (macOS) | BSD-3-Clause |
| `tokenizers` | Apache-2.0 |

Their own dependencies (for example `cryptography`, Apache-2.0 OR BSD-3-Clause,
through MCP's authorization support) are resolved the same way. Each
package's full license text ships with its wheel and is viewable via
`pip show -f <pkg>` after installation.
