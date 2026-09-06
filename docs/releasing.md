# Releasing Youty

A release is complete only when the same version is available from GitHub,
Homebrew, PyPI, the website, and the app's signed automatic-update feed. The app
and DMG must both be signed, accepted by Apple for notarization, and stapled.
An approved release includes source commits and pushes, Apple uploads, publication
on every channel, and verification of the public artifacts.

The maintainer runs one local command, using signing credentials already in the
macOS Keychain:

```bash
./Scripts/release.sh vX.Y.Z --notes "What changed."
./Scripts/release.sh vX.Y.Z --resume
```

The wrapper and machine configuration are deliberately local and ignored by Git.
Public building blocks live in `Scripts/`; `release-check.py` verifies versions,
public downloads, Apple trust, the feed, website, Homebrew formula and bottle,
and a fresh installation of the PyPI package. CI tests these checks.

All channels are mandatory, even if only one component's code changed. App, CLI,
MCP, lockfile, website and Homebrew versions advance together; the app's integer
build number also increases. Unchanged model weights retain their separate pin.

The command waits for source CI, PyPI publishing, and the exact Homebrew bottle
run. Bottle CI installs and runs the public bottle and checks its exact version.
It then verifies the deployed channels before reporting success. A timeout,
failed workflow, missing artifact or mismatched version means **release incomplete**.
Publications happen sequentially across external services; this is not an atomic
transaction. Recovery completes the same release without replacing public bytes.

After an interruption, preserve `build/releases/vX.Y.Z/`, repair the reported
failure, and use `--resume`. A failed GitHub run must be repaired and rerun before
resuming. Unexpected working-tree changes, changed prepared source, conflicting
tags, and different public artifacts stop recovery for review. Do not delete
public releases, move tags, or overwrite artifacts to conceal a partial release.

`.github/workflows/release.yml` is a manually triggered artifact-preparation
workflow. It does not publish a release or run automatically on tags. Publication
belongs to the coordinated command. Package and bottle workflows are subordinate
release steps, not declarations that the whole release is complete.

Available updates are consistent; users can still choose when to install them.
