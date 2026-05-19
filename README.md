# Youty

Save YouTube, Instagram, and TikTok videos to a local folder of Markdown
notes + frame snapshots — searchable from your Mac, your shell, and any
MCP-compatible AI.

Everything runs on your device. No accounts. No telemetry. Your vault is
just a folder of `.md` files and JPEGs you fully own.

## Install

| | How | Need |
|---|---|---|
| **Mac app** | Download `Youty.dmg`, drag to `/Applications` | macOS 26 (Tahoe) |
| **CLI** | `./Scripts/install-cli.sh` &nbsp;or&nbsp; `brew install legetdev/youty/youty` (post-launch) | Xcode 26 to build |
| **MCP server** | `uv tool install ./youty-mcp/dist/*.whl` | Python 3.11+, `uv` |

The Mac app, the `youty` CLI, and the `youty-mcp` server all read and
write the same vault folder.

## Using it

**Mac app.** Open Youty, pick a vault folder once in Settings, paste a
video URL, hit Load → Save to Vault. The Mac app also shows up in:

- Safari / Notes / Mail's Share menu (Share → Save to Youty)
- The macOS Services menu (right-click any URL → Save to Youty Vault)
- Shortcuts.app + Siri (`Save URL to Youty Vault` and two read intents)
- An optional menu bar icon (Settings → Integrations)

**CLI.**

```bash
youty save https://www.youtube.com/watch?v=...
youty list --platform youtube
youty search "ai influencers"
youty transcript <url-or-id>
youty login instagram      # one-time, only for Instagram saves
```

**MCP.** Add `youty-mcp` to your Claude Desktop / Cursor / Claude Code
config and your AI can semantically search the vault, retrieve
transcripts, and find frames. See `youty-mcp/README.md`.

## What lands in the vault

```
{vault}/youtube/Channel - Title/
    video.md          # YAML frontmatter + transcript with timestamps
    00000000.jpg      # frame snapshots, filename = ms offset
    00007560.jpg
    ...
manifest.json         # one-line-per-video corpus index
```

YouTube transcripts are scraped from YouTube's caption panel. TikTok
uses platform auto-captions. Instagram and TikToks-without-captions are
transcribed on-device via Apple's `SpeechAnalyzer` + `SpeechTranscriber`
(macOS 26 only; audio never leaves your Mac).

## Privacy

See [`docs/privacy.md`](docs/privacy.md). The short version: vault is
local, transcripts and frames are local, no telemetry. The only network
calls are (a) platform fetches to scrape the video, and (b) an optional
Gemini API call for AI-search embeddings using a key *you* provide.

## Building from source

```bash
xcodebuild -scheme youty     -configuration Release build   # Mac app
xcodebuild -scheme youty-cli -configuration Release build   # CLI binary
./Scripts/make-dmg.sh                                       # DMG installer
./Scripts/build-mcp-wheel.sh                                # MCP wheel
./Scripts/smoke-test-extractors.sh                          # full smoke
```

No external Swift packages, no bundled binaries, no Python helpers in
the Mac app itself. FFmpeg ships statically linked from
`Vendor/ffmpeg/`. The MCP server is a separate Python package with its
own pinned dependencies.

## Security

Found something concerning? See [`SECURITY.md`](SECURITY.md).

## Open source notice

Youty's Mac app links against FFmpeg 7.1.1 (`libavcodec`, `libavformat`,
`libavutil`, `libswscale`), built from source as statically-linked
archives via [`Scripts/build-ffmpeg.sh`](Scripts/build-ffmpeg.sh).
FFmpeg is licensed under the GNU Lesser General Public License v2.1+
(LGPL-2.1+) — verbatim text in
[`Vendor/ffmpeg/licenses/COPYING.LGPLv2.1`](Vendor/ffmpeg/licenses/COPYING.LGPLv2.1).

The app also bundles Google's SigLIP-Base-Patch16-224 image encoder
(Apache License 2.0) converted to Core ML for frame embedding — verbatim
text in [`Vendor/siglip/licenses/LICENSE`](Vendor/siglip/licenses/LICENSE),
with attribution + conversion provenance in
[`Vendor/siglip/licenses/NOTICE`](Vendor/siglip/licenses/NOTICE).

To relink the app against a modified FFmpeg: edit the FFmpeg source
unpacked by `Scripts/build-ffmpeg.sh`, re-run that script, then re-run
`xcodebuild -scheme youty -configuration Release`. To rebuild the SigLIP
Core ML artifact: edit and re-run
[`Scripts/convert-siglip-coreml.py`](Scripts/convert-siglip-coreml.py).
Pinned versions for both also appear in the app's *About* panel
(Settings → About).

Other third-party components, their licenses, and where to find their
verbatim license texts:
[`THIRD_PARTY_LICENSES.md`](THIRD_PARTY_LICENSES.md).

## License

[MIT](LICENSE). Copyright © Bent Eisheuer.

## Architecture

For builders, [`implementation.md`](implementation.md) is the canonical
source — phase-by-phase rationale, what shipped vs what didn't, every
trade-off documented.
