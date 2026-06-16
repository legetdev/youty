# typed: true
# frozen_string_literal: true

# Homebrew formula for the youty CLI.
#
# Canonical copy lives in the tap repo at legetdev/homebrew-youty/Formula/youty.rb.
# On each release, bump `url` to the new tag's source tarball and set `sha256`
# to `curl -sL <url> | shasum -a 256`.

# Build + install the youty CLI from the tagged GitHub source release.
class Youty < Formula
  desc "Save YouTube, Instagram, and TikTok videos to a local AI-readable knowledge base"
  homepage "https://github.com/legetdev/youty"
  url "https://github.com/legetdev/youty/archive/refs/tags/v1.0.0.tar.gz"
  sha256 "75e78ca0e99a9b82e9a44089b25ca39004fd5b490dbf2c182aaaf8fb08d7f9fa"
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
    # index schema, the on-device models, and the tokenizer live in
    # <prefix>/share/youty/, which SharedResourceLocator.swift checks relative
    # to the binary. This gives the brew CLI the *exact same* text
    # (EmbeddingGemma) + frame (SigLIP) indexing the Mac app performs.
    youty_share = share/"youty"
    youty_share.install "Sources/IndexSchema.sql"

    # Compile the Core ML models (.mlpackage -> .mlmodelc) into share/youty.
    # The weights come from the `models` resource staged above. coremlcompiler
    # emits "<name>.mlmodelc" — the exact name SharedResourceLocator looks up.
    system "xcrun", "coremlcompiler", "compile",
           "Vendor/siglip/models/SigLIP-Base-224_image.mlpackage", youty_share
    system "xcrun", "coremlcompiler", "compile",
           "Vendor/embeddinggemma/models/EmbeddingGemma-300m_text.mlpackage", youty_share

    # The EmbeddingGemma tokenizer artifacts (the native vocab/merges/added
    # tokens the Swift GemmaTokenizer reads from the model's directory).
    youty_share.install "Vendor/embeddinggemma/tokenizer/vocab.bin",
                        "Vendor/embeddinggemma/tokenizer/merges.bin",
                        "Vendor/embeddinggemma/tokenizer/added_tokens.bin"
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
