# Privacy

Youty is local-first. The vault — your saved videos, transcripts, and
frames — lives in a folder on your Mac that you pick. AI search is
**on-device by default**: transcript text is embedded locally with
Google's EmbeddingGemma model (converted to Core ML), so out of the box
nothing about your vault is sent anywhere. The only exception is if you
*explicitly* switch the embedding provider to Gemini in Settings — then,
and only then, transcript text is sent to a Gemini endpoint using a key
*you* provide.

## What goes over the network

| Activity | Where it goes | Why |
|---|---|---|
| YouTube extraction | youtube.com, googlevideo.com | Fetch the player page + the video bytes Youty needs to decode frames. No login. |
| Instagram extraction | instagram.com | Fetch the post page + the CDN URL for the video. Requires you sign in once via the in-app browser. Cookies stored only on your Mac. |
| TikTok extraction | tiktok.com | Fetch the post page + the CDN URL. No login. |
| Speech transcription | nowhere | Apple's on-device `SpeechAnalyzer` runs entirely on your Mac. Audio never leaves. |
| AI-search indexing (default) | nowhere | Transcript text is embedded **on-device** with EmbeddingGemma (Core ML). No key, no network — this is the default. |
| AI-search indexing — Gemini (opt-in) | `generativelanguage.googleapis.com` | **Off by default.** Only if you switch the embedding provider to Gemini in Settings: sends transcript chunks to Gemini for embedding. Your key, your data, your billing. |
| Auto-update | `youtyapp.vercel.app/appcast.xml`, `github.com/legetdev/youty/releases/…` | Sparkle (the bundled auto-update framework) checks once every 24 h for a newer signed release. Only fetches the appcast XML and, if a new version is available, the DMG itself — both pass through EdDSA verification before installation. No identifying information is sent; the request is a plain anonymous HTTPS GET. Disable in *Settings → About* (or set `SUEnableAutomaticChecks=false` in the bundle's Info.plist if you build from source). |

## What stays local

- The vault folder (every saved `video.md` + JPEG).
- The on-device embedding models — EmbeddingGemma (text) and SigLIP
  (frames), both bundled as Core ML inside the app. By default every
  embedding is computed on your Mac; nothing is uploaded to embed it.
- The SQLite search index (`~/Library/Containers/dev.leget.youty/Data/Library/Application Support/Youty/index.db`).
- Your Gemini API key. Stored in a file at the same Application Support
  path, mode `0600`, with macOS file-protection enabled. Never logged,
  never serialized to UserDefaults, never sent in a URL — only as an
  HTTP header to the Gemini endpoint when you've explicitly opted in.
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

If Gemini's terms or behaviour around your key change, that's between
you and Google — Youty is just an HTTP client to their endpoint.
