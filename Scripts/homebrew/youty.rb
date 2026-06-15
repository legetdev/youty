# typed: true
# frozen_string_literal: true

# Homebrew formula for the youty CLI.
#
# Lives in this repo during Phase R prep. At release time the file is
# copied verbatim to `legetdev/homebrew-youty/Formula/youty.rb`, the
# `url` + `sha256` placeholders are replaced against the tagged GitHub
# release tarball, and `brew install legetdev/youty/youty` works.
#
# Phase R checklist for this file:
#   1. Tag a GitHub release (e.g. `v1.0.0`) on the main repo.
#   2. Replace the `url` line so it points at that tag's source tarball.
#   3. Replace `0000…` with the tarball's actual SHA-256:
#        curl -sL <url> | shasum -a 256
#   4. Copy the file into the `homebrew-youty` tap repo (Formula/).
#   5. Verify with `brew install --build-from-source legetdev/youty/youty`.
#   6. Run `brew audit --strict --new legetdev/youty/youty` — must pass
#      before R.9 so the tap doesn't ship with audit warnings.

# Build + install the youty CLI from the tagged GitHub source release.
class Youty < Formula
  desc "Save YouTube, Instagram, and TikTok videos to a local AI-readable knowledge base"
  homepage "https://github.com/legetdev/youty"
  url "https://github.com/legetdev/youty/archive/refs/tags/v1.0.0.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "MIT"
  head "https://github.com/legetdev/youty.git", branch: "main"

  # On-device Core ML model weights (EmbeddingGemma + SigLIP). These live
  # outside git — too large for the repo — and ship as a release asset, so the
  # source tarball above doesn't contain them. Fetched here and laid into
  # Vendor/ before the build. Bump url + sha256 in lockstep with `version`.
  resource "models" do
    url "https://github.com/legetdev/youty/releases/download/v1.0.0/youty-models-1.0.0.tar.gz"
    sha256 "c3139d78af916c3a77ab57986b9729b26d243a1544b2555011b1d59c2560b6d7"
  end

  # macOS 26 Tahoe is required: the SpeechAnalyzer + SpeechTranscriber
  # APIs the transcript pipeline depends on shipped in that release.
  depends_on xcode: ["26.0", :build]
  depends_on macos: :tahoe

  def install
    # The model weights aren't in the git source tarball (externalized to keep
    # the repo lean). Merge the release-asset tarball's Vendor/ tree into the
    # source so xcodebuild finds the .mlpackage build inputs.
    resource("models").stage do
      cp_r "Vendor/.", buildpath/"Vendor"
    end

    # FFmpeg statics live under Vendor/ffmpeg/ — built once via
    # Scripts/build-ffmpeg.sh, committed into the repo so end users
    # never need to install or build FFmpeg themselves.
    xcodebuild "-project", "youty.xcodeproj",
               "-scheme", "youty-cli",
               "-configuration", "Release",
               "-derivedDataPath", "build",
               "SYMROOT=#{buildpath}/build",
               "build"
    bin.install "build/Release/youty"

    # The CLI is a bare binary with no Resources/ bundle of its own, so the
    # SQLite index schema + the SigLIP image encoder live in
    # <prefix>/share/youty/, which SharedResourceLocator.swift checks
    # relative to the binary. The schema is small + lives in the tarball.
    (share/"youty").install "Sources/IndexSchema.sql"

    # TODO(D.4): install the compiled SigLIP image encoder into share/youty so
    # a brew-installed CLI also does frame (image-search) indexing. The weights
    # are now present at build time via the `models` resource above; what's left
    # is compiling the .mlpackage to share/youty for SharedResourceLocator to
    # find at runtime, e.g.:
    #   system "xcrun", "coremlcompiler", "compile",
    #          "Vendor/siglip/models/SigLIP-Base-224_image.mlpackage", share/"youty"
    # Until then a brew-installed CLI does full TEXT indexing on save; frame
    # (image-search) indexing is skipped with a clear, non-fatal warning.
  end

  def caveats
    <<~CAVEATS
      youty (CLI) is now installed. The Mac app is a separate download:
        https://youtyapp.vercel.app

      The MCP server (for Claude Desktop / Cursor / any MCP client) is
      a separate Python package:
        uv tool install youty-mcp

      Quick start:
        youty save https://www.youtube.com/watch?v=...
        youty list
        youty search "..."

      Bug reports + questions: https://github.com/legetdev/youty/issues
    CAVEATS
  end

  test do
    # Lightweight smoke checks — no network calls, no FFmpeg invocation,
    # just confirm the binary runs and reports a sensible version + help.
    assert_match "youty 1.", shell_output("#{bin}/youty --version")
    assert_match "USAGE", shell_output("#{bin}/youty --help")
  end
end
