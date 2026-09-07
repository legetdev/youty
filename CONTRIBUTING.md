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
- **Keep processing local.** Capture, transcription, and embeddings run on-device.
  No remote embedding provider or telemetry. MCP returns requested evidence to
  the user's connected client; its own cloud use is outside Youty's control.
- **Sandbox-safe.** The app is sandboxed: no shell subprocesses, all network via
  `URLSession`/`WKWebView`.
- **Match the surrounding code.** Keep files short and focused; comment intent,
  not mechanics.

## Project layout

| Path | What it is |
|---|---|
| `Sources/` | macOS SwiftUI app and shared capture/indexing pipeline |
| `CLI/` | `youty` command-line binary |
| `Tests/` | Swift unit and regression tests |
| `youty-mcp/` | Python MCP server (has its own tests) |
| `Vendor/` | statically-linked FFmpeg + bundled Core ML models |
| `Scripts/` | build, sign, notarize, release tooling |

## Building

Use an Apple Silicon Mac running macOS 26 or later, Xcode 26, and the project's
existing XcodeGen toolchain. Python 3.11+ and `uv` are needed for MCP development.
`project.yml` is the source of truth for the checked-in Xcode project.

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
uv sync --locked
uv run --locked pytest -q
```

## Verification

Run these commands from the repository root for the behavior you change.
CI runs the Swift unit tests, builds both CLI project variants, tests malformed
media and frame-range handling, and runs the MCP and release-check suites.

```bash
xcodebuild test -project youty.xcodeproj -scheme youty \
  -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
python3 Scripts/verify-updater.py
python3 -m unittest discover -s Scripts -p 'test_release*.py' -v
```

Extractor changes also need a Debug app at the smoke harness's fixed location:

```bash
xcodebuild -scheme youty -configuration Debug -derivedDataPath build/dd build
xcodebuild -scheme youty-cli -configuration Debug -derivedDataPath build/dd build
./Scripts/smoke-test-extractors.sh
```

The harness isolates preferences, indexes, and its temporary vault so it does
not change your saved vault location. Platform availability and sign-in can
affect those probes. The harness skips
Instagram; verify it in the running app after signing in. MCP encoder
changes need the optional macOS model checks documented in
[`youty-mcp/README.md`](youty-mcp/README.md). Fixture tests and compilation alone
do not establish that live extraction or native model inference works.

For publication, follow [`docs/releasing.md`](docs/releasing.md). Individual
packaging scripts are building blocks, not a complete release workflow.

## Pull requests

1. Fork and branch off `main`.
2. Keep the change focused — one concern per PR.
3. Run the relevant checks above and describe any live verification you could not perform.
4. Describe what you changed and how you verified it.

## Reporting bugs / requesting features

Open an issue using the templates. Include your macOS version, the platform
(YouTube / Instagram / TikTok), and exact steps. Note two by-design behaviors
that are **not** bugs: YouTube videos without captions save with no transcript
(there is no audio-ASR fallback), and Instagram requires a one-time in-app login.

## License

By contributing, you agree your contributions are licensed under the
[MIT License](LICENSE).
