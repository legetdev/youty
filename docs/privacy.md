# Privacy

Youty is local-first. The vault — your saved videos, transcripts, and
frames — lives in a folder on your Mac that you pick. AI search is
**100% on-device**: transcript text is embedded locally with Google's
EmbeddingGemma model (converted to Core ML), so nothing about your vault
is ever sent anywhere for search. There is no API key, no provider option,
and no cloud-search exception of any kind.

## What goes over the network

| Activity | Where it goes | Why |
|---|---|---|
| YouTube extraction | youtube.com, googlevideo.com | Fetch the player page + the video bytes Youty needs to decode frames. No login. |
| Instagram extraction | instagram.com | Fetch the post page + the CDN URL for the video. Requires you sign in once via the in-app browser. Cookies stored only on your Mac. |
| TikTok extraction | tiktok.com | Fetch the post page + the CDN URL. No login. |
| Speech transcription | nowhere | Apple's on-device `SpeechAnalyzer` runs entirely on your Mac. Audio never leaves. |
| AI-search indexing | nowhere | Transcript text is embedded **on-device** with EmbeddingGemma (Core ML). No key, no provider option, no network. |
| Auto-update | `youtyapp.vercel.app/appcast.xml`, `github.com/legetdev/youty/releases/…` | Sparkle (the bundled auto-update framework) checks once every 24 h for a newer signed release. Only fetches the appcast XML and, if a new version is available, the DMG itself — both pass through EdDSA verification before installation. No identifying information is sent; the request is a plain anonymous HTTPS GET. Disable in *Settings → About* (or set `SUEnableAutomaticChecks=false` in the bundle's Info.plist if you build from source). |

## What stays local

- The vault folder (every saved `video.md` + JPEG).
- The on-device embedding models — EmbeddingGemma (text) and SigLIP
  (frames), both bundled as Core ML inside the app. Every embedding is
  computed on your Mac; nothing is uploaded to embed it.
- The SQLite search index (`~/Library/Containers/dev.leget.youty/Data/Library/Application Support/Youty/index.db`).
- Your Instagram session cookies, in the Mac app's
  `WKWebsiteDataStore.default()`. Separate from Safari's cookies.

## What Youty never collects

- Analytics, telemetry, crash reports.
- Usage stats. There is no "phone home."
- Identifying information of any kind.

## Third parties

The Mac app bundles a single third-party Swift package, **Sparkle**
(MIT, auto-update), pinned at version 2.9.2 in `Package.resolved` and
green-lit during R.1 decisions after passing the third-party vetting
checklist (long track record, EdDSA-signed updates, single-purpose,
small footprint). FFmpeg still ships statically linked, built from
the upstream FFmpeg source via `Scripts/build-ffmpeg.sh`. The MCP
server (Python, separate package) has a small set of pinned
dependencies declared in `youty-mcp/pyproject.toml`.

The full bundled-and-built-against list — with verbatim license-text
locations — is at [`THIRD_PARTY_LICENSES.md`](../THIRD_PARTY_LICENSES.md).
