#!/usr/bin/env bash
# Reproducible FFmpeg decoder-only build for Youty.
#
# Output: arm64 static libraries in Vendor/ffmpeg/{lib,include}.
# Total footprint: ~6 MB. LGPL only — no GPL components.
#
# Requirements: nasm or yasm (brew install nasm), pkg-config, Xcode CLI tools.
#
# Run from the project root:
#   ./Scripts/build-ffmpeg.sh

set -euo pipefail

FFMPEG_VERSION="7.1.1"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$(mktemp -d)/ffmpeg-build"
PREFIX="$BUILD/install"
SRC="$BUILD/ffmpeg-$FFMPEG_VERSION"

mkdir -p "$BUILD"
cd "$BUILD"
echo "→ Downloading FFmpeg $FFMPEG_VERSION ..."
curl -fsSL -o ffmpeg.tar.xz "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz"
tar -xf ffmpeg.tar.xz

cd "$SRC"
echo "→ Configuring ..."
./configure \
  --prefix="$PREFIX" \
  --disable-everything \
  --enable-static --disable-shared \
  --disable-doc --disable-debug --disable-programs \
  --disable-htmlpages --disable-manpages --disable-podpages --disable-txtpages \
  --enable-network \
  --enable-protocol=https,http,tls,file \
  --enable-securetransport \
  --enable-decoder=h264,hevc,vp9,av1 \
  --enable-demuxer=mov,matroska,webm_dash_manifest \
  --enable-parser=h264,hevc,vp9,av1 \
  --enable-bsf=h264_mp4toannexb \
  --enable-filter=scale --enable-swscale \
  --enable-pic --enable-pthreads --enable-runtime-cpudetect \
  --target-os=darwin --arch=arm64 \
  --extra-cflags="-arch arm64 -mmacosx-version-min=15.0" \
  --extra-ldflags="-arch arm64 -mmacosx-version-min=15.0"

echo "→ Building ..."
make -j"$(sysctl -n hw.ncpu)"
make install

echo "→ Copying into project ..."
mkdir -p "$ROOT/Vendor/ffmpeg/lib" "$ROOT/Vendor/ffmpeg/include"
cp "$PREFIX/lib/"libav{codec,format,util}.a "$PREFIX/lib/libswscale.a" "$ROOT/Vendor/ffmpeg/lib/"
rm -rf "$ROOT/Vendor/ffmpeg/include/"*
cp -R "$PREFIX/include/"libav{codec,format,util} "$PREFIX/include/libswscale" "$ROOT/Vendor/ffmpeg/include/"

# Copy FFmpeg's canonical license texts alongside the static libs so the
# LGPL §1 obligation ("accompany the work with a copy of the License") is
# satisfied for anyone shipping a binary built from this repo.
echo "→ Copying FFmpeg license texts ..."
mkdir -p "$ROOT/Vendor/ffmpeg/licenses"
cp "$SRC/COPYING.LGPLv2.1" "$ROOT/Vendor/ffmpeg/licenses/COPYING.LGPLv2.1"
[ -f "$SRC/COPYING.LGPLv3" ] && cp "$SRC/COPYING.LGPLv3" "$ROOT/Vendor/ffmpeg/licenses/COPYING.LGPLv3"
cp "$SRC/CREDITS" "$ROOT/Vendor/ffmpeg/licenses/CREDITS" 2>/dev/null || true

echo "→ Done."
du -sh "$ROOT/Vendor/ffmpeg/lib"
