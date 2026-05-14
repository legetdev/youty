# Privacy

Youty is local-first. The vault — your saved videos, transcripts, and
frames — lives in a folder on your Mac that you pick. Nothing about it
is sent anywhere unless you explicitly enable AI-search indexing (and
even then only the transcript text is sent, and only to a Gemini
endpoint using a key *you* provide).

## What goes over the network

| Activity | Where it goes | Why |
|---|---|---|
| YouTube extraction | youtube.com, googlevideo.com | Fetch the player page + the video bytes Youty needs to decode frames. No login. |
| Instagram extraction | instagram.com | Fetch the post page + the CDN URL for the video. Requires you sign in once via the in-app browser. Cookies stored only on your Mac. |
| TikTok extraction | tiktok.com | Fetch the post page + the CDN URL. No login. |
| Speech transcription | nowhere | Apple's on-device `SpeechAnalyzer` runs entirely on your Mac. Audio never leaves. |
| AI-search indexing (optional) | `generativelanguage.googleapis.com` | Sends the transcript chunks to Gemini for embedding. Your key, your data, your billing. Skip this by leaving the Gemini API key field empty in Settings. |

## What stays local

- The vault folder (every saved `video.md` + JPEG).
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

Youty has zero third-party Swift dependencies in the Mac app. FFmpeg
ships statically linked, built from the upstream FFmpeg source via
`Scripts/build-ffmpeg.sh`. The MCP server (Python, separate package)
has a small set of pinned dependencies declared in
`youty-mcp/pyproject.toml`.

If Gemini's terms or behaviour around your key change, that's between
you and Google — Youty is just an HTTP client to their endpoint.
