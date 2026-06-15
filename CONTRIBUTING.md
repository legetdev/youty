# Contributing to Youty

Thanks for your interest in improving Youty. This is a small, focused project —
a macOS app, a `youty` CLI, and a Python `youty-mcp` server that turn YouTube,
Instagram, and TikTok videos into a local, AI-readable knowledge base. Search
runs 100% on-device. Contributions that keep it lean, private, and fast are very
welcome.

## Ground rules

- **No new third-party dependencies** in the Swift app/CLI. The only allowed
  Swift Package is Sparkle (auto-update); FFmpeg is statically linked. Open an
  issue before proposing anything else.
- **Stay on-device.** No feature may send user data, transcripts, or frames to a
  remote service. No API keys, no accounts, no telemetry.
- **Sandbox-safe.** The app is sandboxed: no shell subprocesses, all network via
  `URLSession`/`WKWebView`.
- **Match the surrounding code.** Keep files short and focused; comment intent,
  not mechanics.

## Project layout

| Path | What it is |
|---|---|
| `Sources/` | macOS SwiftUI app |
| `CLI/` | `youty` command-line binary |
| `youty-mcp/` | Python MCP server (has its own tests) |
| `Vendor/` | statically-linked FFmpeg + bundled Core ML models |
| `Scripts/` | build, sign, notarize, release tooling |

## Building

The on-device Core ML models (~415 MB) live outside git and are fetched from
the matching GitHub Release. Grab them once (checksummed, idempotent; the
install/release scripts also call it automatically):

```bash
./Scripts/fetch-models.sh
```

This is an XcodeGen project. After changing `project.yml` (or adding/removing
source files), regenerate:

```bash
xcodegen generate
```

Then build:

```bash
xcodebuild -scheme youty     -configuration Debug build   # the app
xcodebuild -scheme youty-cli -configuration Debug build   # the CLI
```

MCP server:

```bash
cd youty-mcp
uv sync
uv run pytest -q     # tests must stay green
```

## Pull requests

1. Fork and branch off `main`.
2. Keep the change focused — one concern per PR.
3. Verify it builds and (for the MCP) that `uv run pytest -q` passes.
4. Describe what you changed and how you verified it.

## Reporting bugs / requesting features

Open an issue using the templates. Include your macOS version, the platform
(YouTube / Instagram / TikTok), and exact steps. Note two by-design behaviors
that are **not** bugs: YouTube videos without captions save with no transcript
(there is no audio-ASR fallback), and Instagram requires a one-time in-app login.

## License

By contributing, you agree your contributions are licensed under the
[MIT License](LICENSE).
