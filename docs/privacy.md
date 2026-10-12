# Privacy

Youty is local-first. The vault — your saved videos, transcripts, and
frames — lives in a folder on your Mac that you pick. AI search is
**100% on-device**: transcript text, on-screen text, frames, and search queries
are embedded locally with Google's EmbeddingGemma 2 model (Core ML), without
sending query text or vault contents to a remote embedding service. No
embedding API key is required.
When you connect an AI assistant through MCP, Youty returns requested transcripts,
metadata, and images to that client. The client's settings and provider policies
determine whether it sends those results to a cloud service.

## What goes over the network

| Activity | Where it goes | Why |
|---|---|---|
| YouTube extraction | youtube.com, googlevideo.com | Fetch the player page + the video bytes Youty needs to decode frames. For a video without captions, also its audio stream, which is transcribed on your Mac. No login. |
| Instagram extraction | instagram.com and its media CDNs | Fetch the post page and video. Requires you sign in once via the in-app browser. Session cookies are stored on your Mac and sent to Instagram as needed for authenticated requests. |
| TikTok extraction | tiktok.com and its media CDNs | Fetch the post page and video. No login. |
| Speech transcription | Apple for missing language assets | Apple's `SpeechAnalyzer` transcribes on-device. Required language assets may download first; audio is not uploaded for transcription. |
| AI-search indexing | nowhere | Transcripts, on-screen text, and frames are embedded **on-device** with EmbeddingGemma 2 (Core ML). No key, no provider option, no network. |
| MCP setup | PyPI and its download CDN; GitHub release assets only without the app or CLI | Install the Python package and its dependencies (Claude Desktop's extension does this with its own bundled uv). The server reuses the models of an installed Youty app or CLI; otherwise it downloads Youty's checksummed models asset once. Queries are always embedded locally. |
| Saving from your AI | the platform, as for any save | `save_video` hands the link to the Youty app on your Mac, which saves it like a pasted link. |
| Auto-update | `youtyapp.vercel.app/appcast.xml`, `github.com/legetdev/youty/releases/…` | Sparkle checks the HTTPS feed once every 24 hours while the app runs. Downloaded release archives are verified with EdDSA before installation; the XML feed itself is delivered over HTTPS. Settings → About also offers a manual check. |

Network services receive ordinary connection information, including your IP
address and request headers. Platform requests also identify the video you ask
Youty to load. A local vault stored in an iCloud or other synced folder is subject
to that service's synchronization settings.

## What stays local

- The vault folder (every saved `video.md` + JPEG), unless you sync or share it.
- The on-device embedding model — EmbeddingGemma 2 (text and frames),
  bundled as Core ML inside the app. Every embedding is computed on your Mac;
  nothing is uploaded to embed it.
- The SQLite search index (`~/Library/Containers/dev.leget.youty/Data/Library/Application Support/Youty/index.db`).
- Your stored Instagram session, in the Mac app's
  `WKWebsiteDataStore.default()`. Separate from Safari's cookies.

## What Youty never collects

- Analytics, telemetry, crash reports.
- Usage stats. There is no "phone home."
- A Youty account or user profile.

## Third parties

The Mac app bundles a single third-party Swift package, **Sparkle**
(MIT, auto-update), pinned at version 2.10.0 in `Package.resolved` and
green-lit after passing the third-party vetting
checklist (long track record, EdDSA-signed updates, single-purpose,
small footprint). FFmpeg still ships statically linked, built from
the upstream FFmpeg source via `Scripts/build-ffmpeg.sh`. The MCP
server (Python, separate package) has runtime
dependencies bounded in `youty-mcp/pyproject.toml` and locked in `uv.lock`.

The full bundled-and-built-against list — with verbatim license-text
locations — is at [`THIRD_PARTY_LICENSES.md`](../THIRD_PARTY_LICENSES.md).
