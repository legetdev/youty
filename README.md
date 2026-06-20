# Youty

Save YouTube, Instagram, and TikTok videos to a local folder of Markdown
notes + frame snapshots — searchable from your Mac, your shell, and any
MCP-compatible AI.

Everything runs on your device. No accounts. No telemetry. Your vault is
just a folder of `.md` files and JPEGs you fully own.

## Install

| | How | Need |
|---|---|---|
| **Mac app** | Download the DMG from [Releases](https://github.com/legetdev/youty/releases/latest), drag to `/Applications` | macOS 26 (Tahoe) |
| **CLI** | `brew install legetdev/youty/youty` &nbsp;or&nbsp; `./Scripts/install-cli.sh` from a clone | Xcode 26 to build |
| **MCP server** | wire `uvx youty-mcp@latest` into your MCP client (e.g. `claude mcp add youty -- uvx youty-mcp@latest`) — always the newest, no manual upgrade | Python 3.11+, `uv` |

The Mac app auto-updates via Sparkle once installed — *Check for
Updates…* lives in the app menu (or *Settings → About*). New releases
are EdDSA-signed; an unsigned binary will be rejected even if the
appcast URL is hijacked.

The Mac app, the `youty` CLI, and the `youty-mcp` server all read and
write the same vault folder.

## Using it

**Mac app.** First launch walks you through a four-card setup (pick a
vault; AI search works on-device with no key; optional CLI install;
optional MCP wiring).
The cards stay reachable from *Settings → Onboarding*. After that:
paste a video URL, hit Load → Save to Vault. The Mac app also shows up in:

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
youty reindex --text-only  # re-embed the vault for on-device search
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
local, transcripts and frames are local, **AI search is 100% on-device**,
no telemetry. Text search uses Google's EmbeddingGemma converted to Core ML
and runs entirely on your Mac — no API key, no provider option, nothing
leaves the device. The only network calls are (a) platform fetches to
scrape the video, and (b) Sparkle's anonymous once-a-day check for a newer
Youty release.

## Terms

See [`docs/terms.md`](docs/terms.md). Same posture as yt-dlp and IINA:
Youty is a personal user-agent that loads pages you're already entitled
to view; you're responsible for whether your use of the saved content
complies with each platform's terms of service.

## Building from source

The on-device Core ML models (~415 MB) aren't committed — they're fetched from
the matching GitHub Release. Run this once before building (it's a checksummed,
idempotent no-op once they're in place); `install-cli.sh` and `release-app.sh`
call it for you:

```bash
./Scripts/fetch-models.sh                                   # models → Vendor/ (one-time)
```

```bash
xcodebuild -scheme youty     -configuration Release build   # Mac app
xcodebuild -scheme youty-cli -configuration Release build   # CLI binary
./Scripts/make-dmg.sh                                       # DMG installer (versioned filename)
./Scripts/build-mcp-wheel.sh                                # MCP wheel + twine check
./Scripts/smoke-test-extractors.sh                          # full smoke
```

Release pipeline (requires a Developer ID certificate + a notarytool
keychain profile):

```bash
export DEVELOPER_ID_APPLICATION_CERT="Developer ID Application: ... (TEAMID)"
export NOTARY_KEYCHAIN_PROFILE="youty-notary"
./Scripts/release-app.sh                              # build → sign → notarize → staple
./Scripts/make-dmg.sh                                 # signed versioned DMG
./Scripts/sparkle-sign-and-cut.sh build/Youty-*.dmg   # emits the appcast <item>
```

One vetted Swift Package dependency in the Mac app (**Sparkle**, MIT,
auto-update — pinned in `Package.resolved`). FFmpeg ships statically
linked from `Vendor/ffmpeg/`. The MCP server is a separate Python
package with its own pinned dependencies.

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

The app also bundles Google's EmbeddingGemma-300m text encoder, converted
to Core ML for on-device AI search (the default — no API key). It is
distributed under the **Gemma Terms of Use** (not an OSI license;
commercial use + redistribution permitted with attribution) — the required
NOTICE + modification record is in
[`Vendor/embeddinggemma/licenses/EmbeddingGemma-NOTICE.txt`](Vendor/embeddinggemma/licenses/EmbeddingGemma-NOTICE.txt),
and the canonical terms live at <https://ai.google.dev/gemma/terms>. A
from-scratch Swift BPE tokenizer reproduces Gemma's tokenizer with no
third-party dependency.

The app also bundles Sparkle (MIT, the auto-update framework). Pinned
at version 2.9.2 in
[`Package.resolved`](youty.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved);
license text ships inside the framework at
`Sparkle.framework/Versions/Current/Resources/LICENSE`. Vetted against
the third-party checklist (MIT, 20-year track record, EdDSA-signed
updates, single-purpose).

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

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the project layout, build steps,
and ground rules.
