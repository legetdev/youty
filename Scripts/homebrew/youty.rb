# Homebrew formula scaffold for the youty CLI.
#
# Lives in the main repo while Phase R is still ahead. At distribution
# time this file will be moved to `legetdev/homebrew-youty/Formula/youty.rb`
# and the `url` / `sha256` will point at the first tagged GitHub release.
# Until then, users build the CLI from source via `Scripts/install-cli.sh`.
#
# Phase R checklist for this file:
#   1. Tag a GitHub release (e.g. `v1.0.0`).
#   2. Replace `url` + `sha256` with the tagged tarball URL and its sha.
#   3. Copy this file to the `homebrew-youty` tap repo.
#   4. `brew install legetdev/youty/youty` should then work.

class Youty < Formula
  desc "Save YouTube, Instagram, and TikTok videos to a local AI-readable knowledge base"
  homepage "https://github.com/legetdev/youty"
  url "https://github.com/legetdev/youty/archive/refs/tags/v1.0.0.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "MIT"
  head "https://github.com/legetdev/youty.git", branch: "main"

  depends_on xcode: ["26.0", :build]
  depends_on :macos => :sequoia

  def install
    # FFmpeg statics ship inside Vendor/ffmpeg/. No external deps required.
    system "xcodebuild",
           "-project", "youty.xcodeproj",
           "-scheme", "youty-cli",
           "-configuration", "Release",
           "-derivedDataPath", "build",
           "SYMROOT=#{buildpath}/build",
           "build"
    bin.install "build/Release/youty"
  end

  test do
    assert_match "youty 1.", shell_output("#{bin}/youty --version")
    assert_match "USAGE", shell_output("#{bin}/youty --help")
  end
end
