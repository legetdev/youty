# youty-mcp

Local MCP server that lets AI assistants use the videos you saved with
[Youty](https://youtyapp.vercel.app): Claude Desktop, Claude Code, Cursor,
VS Code, Codex, Gemini CLI, Windsurf, Cline, and any other MCP client.

## What your AI can do

| Tool | What it does |
|---|---|
| `search(query, videos=8, platform?, since?, kind?)` | One ranking over what videos **said**, what they **showed on screen** (slides, code, URLs), and what was **visible** in frames — grouped by video, up to three moments each, every moment with a link that opens the video at that time. Any language. |
| `get_transcript(video_id, start_ms?, end_ms?, include_on_screen_text?)` | The transcript as timestamped paragraphs, about 6K tokens per page, with the start of the next page. |
| `get_video(video_id)` | Overview: details, description, and chapters (the creator's own, or evenly spaced sections). |
| `view_frames(video_id, frame_ms?, max_frames=6)` | The frames themselves, as images any client can see. |
| `list_videos(platform?, channel?, limit=50)` | What's saved, newest first. |
| `find_similar(video_id, k=8)` | Saved videos closest in content to one you have. |
| `save_video(url)` | Saves a YouTube, Instagram, or TikTok link through the Youty app and returns once it's searchable. |

The server also tells clients when to use Youty (MCP `instructions`), so an
assistant reaches for your vault before the web when a question concerns
videos you saved. Responses are compact Markdown sized to stay well inside
client limits.

## Install

**Claude Desktop:** in the Youty app, *Settings → Onboarding → Add to Claude
Desktop* — or open [`Youty.mcpb`](https://github.com/legetdev/youty/releases/latest/download/Youty.mcpb).
Claude Desktop brings its own runtime; nothing else to install.

**Claude Code:** install the plugin (adds the server plus a short research skill):

```bash
claude plugin marketplace add legetdev/youty && claude plugin install youty@youty
```

**Everything else** (needs [uv](https://docs.astral.sh/uv/): `brew install uv`):

```bash
uvx youty-mcp@latest install           # wires every MCP client it finds
uvx youty-mcp@latest install --list    # supported clients + config paths
uvx youty-mcp@latest install cursor    # just one
uvx youty-mcp@latest uninstall         # remove Youty again
```

The installer merges a `youty` entry into each client's config, preserves your
other settings, is safe to re-run, and skips clients that already have Youty
through the plugin or extension. Clients launch `uvx youty-mcp@latest` on a
Python that has Core ML wheels (uvx ignores the package's own range), so a
restart always loads the newest server with full on-device search. To wire a client by hand, use
`{"command": "uvx", "args": ["--python", ">=3.11,<3.14", "youty-mcp@latest"]}`.

## On-device search

Queries are embedded on your Mac with Google's **EmbeddingGemma 2** (Apache-2.0)
— the same model the Youty app used to index transcripts, on-screen text, and
frames, so one query vector compares against all three. It runs on the CPU in
a small helper process that starts with the first search (well under a second)
and exits ten minutes after the last one, so an idle server holds no model in
memory. Later searches take about 40 ms each. Keyword matching (SQLite FTS5) runs
alongside it for exact names and terms. No key, no account, no remote
embedding call.

The server reuses the model files of an installed Youty app or Homebrew CLI.
Only if neither is present does it download Youty's checksummed models asset
once into `~/.cache/youty/models/`. Set `YOUTY_MODELS_DIR` to use a local copy.

Your AI client receives the results it requests and may send them to its own
provider under its own privacy settings.

## Index location

The Mac app is sandboxed, and macOS blocks other programs from its storage
unless you grant them extra permissions. So after every save the app shares a
copy of its index in the vault, at `{vault}/.youty/index.db`, and the server
searches that copy. No permission prompt is involved, and updates show up
without restarting the server.

The server finds the vault through `YOUTY_VAULT`, the CLI's saved vault,
Spotlight, or a short scan of Documents, Desktop and iCloud Drive. Set
`YOUTY_VAULT=/abs/path` if your vault lives somewhere Spotlight doesn't index.
Without a shared copy it reads the app's index directly when macOS allows it,
then the CLI's own index (`~/Library/Application Support/Youty/index.db`).
`YOUTY_INDEX_DB=/abs/path` points it at one specific index. The index is
rebuildable from the vault's `video.md` files and frames: *Settings → Re-index
entire vault* in the app.

## Develop

```bash
cd youty-mcp
uv sync --locked
uv run pytest -q
```

## Troubleshooting

- **No results** — check that the vault has videos (`list_videos`) and that
  indexing is on in the app (*Settings → AI search index*).
- **"keyword matching only"** — the on-device model couldn't load. Install or
  update the Youty app, or let the one-time model download finish.
- **Just updated Youty** — the app upgrades existing saves to the new search
  model in the background on first launch; keyword search works meanwhile.
- **"macOS doesn't let this AI app read it"** — the Youty app is older than
  2.0.3 and doesn't share its index yet. Update Youty and open it once.
- **"getting its search index ready"** — a current Youty app hasn't shared
  its index yet. Open the app: it shares the index within seconds of launch,
  and the next search here picks it up.
- **"No Youty library was found"** — open the app once after saving a video.
  If your vault is outside Spotlight's reach (for example on an external
  drive), set `YOUTY_VAULT` in your AI app's Youty entry.
- The server never refuses to start: when something is wrong, every tool
  answers with what to do, and it recovers on its own once that's fixed.
- Logs: `~/Library/Logs/Youty/youty-mcp.log`.
