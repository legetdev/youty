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

## License

[MIT](LICENSE). Copyright © Bent Eisheuer.

## Architecture

For builders, [`implementation.md`](implementation.md) is the canonical
source — phase-by-phase rationale, what shipped vs what didn't, every
trade-off documented.
