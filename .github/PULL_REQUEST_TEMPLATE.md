<!-- Thanks for contributing to Youty. Keep PRs focused — one concern each. -->

## What does this change?

<!-- A short summary of the change and the problem it solves. -->

## How was it verified?

<!-- Builds cleanly? Tested on which surface (app / CLI / MCP)? `uv run pytest -q` green? -->

## Checklist

- [ ] Builds locally (`xcodebuild` for app/CLI; `uv run pytest -q` for the MCP)
- [ ] No new third-party dependencies (Sparkle + statically-linked FFmpeg only)
- [ ] Stays 100% on-device — no network calls with user data, no keys, no telemetry
- [ ] Sandbox-safe (no subprocesses; network via `URLSession`/`WKWebView`)
- [ ] Regenerated the Xcode project if `project.yml` or source files changed (`xcodegen generate`)
