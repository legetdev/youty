# typed: true
# frozen_string_literal: true

# Homebrew formula for the youty CLI.
#
# Canonical copy lives in the tap repo at legetdev/homebrew-youty/Formula/youty.rb.
# Scripts/release.sh synchronizes the source checksum and verified bottle.

# Build + install the youty CLI from the tagged GitHub source release.
class Youty < Formula
  desc "Save YouTube, Instagram, and TikTok videos to a local AI-readable knowledge base"
  homepage "https://github.com/legetdev/youty"
  url "https://github.com/legetdev/youty/archive/refs/tags/v2.0.4.tar.gz"
  sha256 "4d4e0ae5f6b63ec286cd4d71add69d7435ad9f1f0fa44028f7fa7f513c56deba"
  license "MIT"
  head "https://github.com/legetdev/youty.git", branch: "main"

  bottle do
    root_url "https://github.com/legetdev/youty/releases/download/v2.0.4"
    sha256 cellar: :any_skip_relocation, arm64_tahoe: "ad6071714efa8f6989a2ee7e066a381dc26be2e5b8cea8c4c421b6294f624137"
  end







  # Bottles (instant binary install) are built + verified on a macOS 26 runner by
  # .github/workflows/bottle.yml, which injects a `bottle do … end` block here with
  # the real per-arch sha256s. Until a matching bottle exists, brew transparently
  # falls back to the from-source build below — so this formula always installs.

  # On-device EmbeddingGemma 2 model weights, tables, and tokenizer. These live
  # outside git — too large for the repo — and ship as a release asset, so the
  # source tarball above doesn't contain them. Fetched here and laid into
  # Vendor/ before the build. This separate pin changes only with model weights.
  resource "models" do
    url "https://github.com/legetdev/youty/releases/download/models-2.0.0/youty-models-2.0.0.tar.gz"
    sha256 "d0fb8541138a0460a59eb869cdc4cb13563d31fb8bc30bbd1a69793c5b3340f4"
  end

  # macOS 26 Tahoe is required: the SpeechAnalyzer + SpeechTranscriber
  # APIs the transcript pipeline depends on shipped in that release.
  depends_on xcode: ["26.0", :build]
  depends_on macos: :tahoe
  # Generates the Sparkle-free, CLI-only Xcode project (project-cli.yml) at build
  # time so xcodebuild never evaluates the app's Sparkle SPM manifest, which
  # fails inside Homebrew's build sandbox.
  depends_on "xcodegen" => :build

  def install
    # The model weights aren't in the git source tarball (externalized to keep
    # the repo lean). Merge the release-asset tarball's Vendor/ tree into the
    # source so xcodebuild finds the .mlpackage build inputs. Homebrew strips the
    # asset's single top-level "Vendor/" dir on stage, so the CWD here holds its
    # contents (embeddinggemma2/) — merge it into the source's Vendor/,
    # which already carries the .mlpackage Manifests + FFmpeg statics from git.
    resource("models").stage do
      Dir["*"].each do |sub|
        dest = buildpath/"Vendor"/sub
        dest.mkpath
        cp_r "#{sub}/.", dest
      end
    end

    # Generate the Sparkle-free CLI project (no SPM packages -> no SwiftPM
    # manifest sandbox under brew) and build it. FFmpeg statics live under
    # Vendor/ffmpeg/ — built once via Scripts/build-ffmpeg.sh, committed into the
    # repo so end users never need to install or build FFmpeg themselves.
    system "xcodegen", "generate", "--spec", "project-cli.yml"
    xcodebuild "-project", "youty-cli.xcodeproj",
               "-scheme", "youty-cli",
               "-configuration", "Release",
               "-derivedDataPath", "build",
               "SYMROOT=#{buildpath}/build",
               "build"
    bin.install "build/Release/youty"

    # The CLI is a bare binary with no Resources/ bundle of its own, so the
    # index schema, the on-device models, and the tokenizer live in
    # <prefix>/share/youty/, which SharedResourceLocator.swift checks relative
    # to the binary. This gives the brew CLI the *exact same* text and frame
    # indexing (EmbeddingGemma 2) the Mac app performs; the youty-mcp server
    # also reuses these files for query embedding instead of downloading them.
    youty_share = share/"youty"
    youty_share.install "Sources/IndexSchema.sql"

    # Compile the Core ML models (.mlpackage -> .mlmodelc) into share/youty.
    # coremlcompiler emits "<name>.mlmodelc" — the name SharedResourceLocator
    # looks up.
    %w[EmbeddingGemma2Text EmbeddingGemma2Vision].each do |model|
      system "xcrun", "coremlcompiler", "compile",
             "Vendor/embeddinggemma2/models/#{model}.mlpackage", youty_share
    end

    # Token and position tables, the native tokenizer artifacts the Swift
    # GemmaTokenizer reads, Google's tokenizer.json for the MCP server, and
    # the model license + NOTICE.
    youty_share.install "Vendor/embeddinggemma2/resources/EmbeddingGemma2Tokens.bf16",
                        "Vendor/embeddinggemma2/resources/EmbeddingGemma2Positions.f16",
                        "Vendor/embeddinggemma2/tokenizer/vocab.bin",
                        "Vendor/embeddinggemma2/tokenizer/merges.bin",
                        "Vendor/embeddinggemma2/tokenizer/added_tokens.bin",
                        "Vendor/embeddinggemma2/tokenizer/tokenizer.json",
                        "Vendor/embeddinggemma2/licenses/EmbeddingGemma2-LICENSE.txt",
                        "Vendor/embeddinggemma2/licenses/EmbeddingGemma2-NOTICE.txt"
  end

  def caveats
    <<~CAVEATS
      youty (CLI) is now installed. The Mac app is a separate download:
        https://youtyapp.vercel.app

      Connect your AI assistant (Claude Code, Codex, Cursor, …) to your
      saved videos with one command — it wires every client it finds:
        uvx youty-mcp@latest install

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
    assert_match(/youty \d+\./, shell_output("#{bin}/youty --version"))
    assert_match "USAGE", shell_output("#{bin}/youty --help")
  end
end
