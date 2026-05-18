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
- **License:** Apache License 2.0.
- **Project home:** <https://github.com/asg017/sqlite-vec>.
- **Full license text:** <https://github.com/asg017/sqlite-vec/blob/main/LICENSE>
  (Apache-2.0 standard text — also reproduced in the installed wheel).

---

## SQLite

- **Component:** SQLite, used both directly (Swift) and via Python's stdlib
  in the MCP server.
- **License:** SQLite is in the public domain.
  <https://www.sqlite.org/copyright.html>.
- **Project home:** <https://www.sqlite.org>.

---

## Apple MobileCLIP-S2 (CoreML)

- **Component:** ML model + tokenizer for frame embeddings. Downloaded lazily
  on first use to `~/Library/Application Support/Youty/models/`.
- **Source:** `https://huggingface.co/apple/coreml-mobileclip`.
- **License:** Apple Sample Code License — see the upstream
  `LICENSE` at <https://huggingface.co/apple/coreml-mobileclip/blob/main/LICENSE>.
- **Note:** Apple's model weights are downloaded by the end user from
  Apple's own HuggingFace org; Youty does not bundle or redistribute them.

---

## OpenAI CLIP tokenizer vocabulary

- **Component:** BPE vocab + merges files for the CLIP tokenizer used
  alongside MobileCLIP-S2. Downloaded lazily from
  `https://huggingface.co/openai/clip-vit-base-patch32`.
- **License:** MIT — see <https://github.com/openai/CLIP/blob/main/LICENSE>.
- **Note:** Downloaded by the end user from OpenAI's HuggingFace org;
  Youty does not bundle or redistribute these files.

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
| `sqlite-vec` | Apache-2.0 |
| `httpx` | BSD-3-Clause |
| `numpy` | BSD-3-Clause |
| `coremltools` | BSD-3-Clause |

Each package's full license text ships with its wheel and is
viewable via `pip show -f <pkg>` after installation.
