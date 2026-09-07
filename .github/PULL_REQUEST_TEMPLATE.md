<!-- Thanks for contributing to Youty. Keep PRs focused — one concern each. -->

## What does this change?

<!-- A short summary of the change and the problem it solves. -->

## How was it verified?

<!-- Builds cleanly? Tested on which surface (app / CLI / MCP)? `uv run pytest -q` green? -->

## Checklist

- [ ] Relevant build and regression checks pass (see `CONTRIBUTING.md`)
- [ ] No new third-party dependencies (Sparkle + statically-linked FFmpeg only)
- [ ] Processing stays local; no remote embeddings or telemetry; MCP disclosure remains accurate
- [ ] Mac app remains sandbox-safe (no subprocesses; network via `URLSession`/`WKWebView`)
- [ ] Regenerated the Xcode project if `project.yml` or source files changed (`xcodegen generate`)
