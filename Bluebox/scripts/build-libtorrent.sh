#!/bin/bash
#
# Builds LibTorrentEngine.xcframework from source: libtorrent (a pinned
# release, checksum-verified) plus Bluebox's Objective-C++ wrapper
# (Packages/BlueboxKit/LibTorrent/LibTorrentEngine/BBTorrent.mm), as static
# libraries for:
#
#   ios-arm64                    iPhone and iPad
#   ios-arm64_x86_64-simulator   iOS Simulator
#   macos-arm64                  Mac (Apple silicon)
#
# No OpenSSL: hashing uses Apple's CommonCrypto, and protocol encryption uses
# libtorrent's built-in RC4 and Diffie-Hellman. Without a TLS library,
# HTTPS trackers and web seeds, SSL torrents and WebTorrent are unavailable
# (HTTP and UDP trackers, the DHT, PEX and LSD all work).
#
# Needs: Xcode, CMake, Ninja, and Boost's headers (brew install cmake ninja boost).
# Usage: scripts/build-libtorrent.sh [-j N]      (default -j 3)
#
set -euo pipefail

LIBTORRENT_VERSION="2.1.2"
LIBTORRENT_SHA256="3362546d9cd71b9e49ee6cac7d3f1f914ce9cdb217c86b63d5b22cbed0334dbc"
LIBTORRENT_URL="https://github.com/arvidn/libtorrent/releases/download/v${LIBTORRENT_VERSION}/libtorrent-rasterbar-${LIBTORRENT_VERSION}.tar.gz"
IOS_MIN="18.0"
MACOS_MIN="15.0"

JOBS=3
while getopts "j:" opt; do
  case "$opt" in
    j) JOBS="$OPTARG" ;;
    *) echo "usage: $0 [-j jobs]" >&2; exit 2 ;;
  esac
done

REPO="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE="$REPO/Packages/BlueboxKit/LibTorrent/LibTorrentEngine"
OUTPUT="$REPO/Packages/BlueboxKit/LibTorrent/LibTorrentEngine.xcframework"
WORK="${BLUEBOX_LIBTORRENT_WORK:-$REPO/build/libtorrent}"
SRC="$WORK/src/libtorrent-rasterbar-${LIBTORRENT_VERSION}"

for tool in cmake ninja xcrun xcodebuild libtool shasum curl; do
  command -v "$tool" >/dev/null || { echo "error: $tool not found" >&2; exit 1; }
done

BOOST_INCLUDE="${BOOST_INCLUDE:-}"
if [ -z "$BOOST_INCLUDE" ] && command -v brew >/dev/null; then
  BOOST_INCLUDE="$(brew --prefix boost 2>/dev/null)/include"
fi
[ -f "$BOOST_INCLUDE/boost/version.hpp" ] || { echo "error: Boost headers not found (brew install boost, or set BOOST_INCLUDE)" >&2; exit 1; }
BOOST_ROOT_DIR="$(dirname "$BOOST_INCLUDE")"

# --- Source -----------------------------------------------------------------

mkdir -p "$WORK/src"
TARBALL="$WORK/src/libtorrent-rasterbar-${LIBTORRENT_VERSION}.tar.gz"
if [ ! -f "$TARBALL" ]; then
  echo "==> Downloading libtorrent ${LIBTORRENT_VERSION}"
  curl -fsSL -o "$TARBALL.part" "$LIBTORRENT_URL"
  mv "$TARBALL.part" "$TARBALL"
fi
ACTUAL="$(shasum -a 256 "$TARBALL" | cut -d' ' -f1)"
if [ "$ACTUAL" != "$LIBTORRENT_SHA256" ]; then
  echo "error: checksum mismatch for $TARBALL" >&2
  echo "  expected $LIBTORRENT_SHA256" >&2
  echo "  got      $ACTUAL" >&2
  exit 1
fi
if [ ! -f "$SRC/CMakeLists.txt" ]; then
  tar -xzf "$TARBALL" -C "$WORK/src"
fi

# --- One slice ----------------------------------------------------------------

# build_slice <name> <system> <sdk> <archs> <deployment target>
build_slice() {
  local name="$1" system="$2" sdk="$3" archs="$4" minos="$5"
  local dir="$WORK/build-$name"
  local sysroot
  sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
  echo "==> Building $name ($archs)"

  local system_args=()
  if [ "$system" = "iOS" ]; then
    system_args=(-DCMAKE_SYSTEM_NAME=iOS)
  fi

  cmake -S "$ENGINE" -B "$dir" -G Ninja \
    ${system_args[@]+"${system_args[@]}"} \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_SYSROOT="$sysroot" \
    -DCMAKE_OSX_ARCHITECTURES="$archs" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$minos" \
    -DCMAKE_C_FLAGS="-DTORRENT_USE_COMMONCRYPTO=1" \
    -DCMAKE_CXX_FLAGS="-DTORRENT_USE_COMMONCRYPTO=1 -Wno-deprecated-declarations" \
    -DCMAKE_OBJCXX_FLAGS="-DTORRENT_USE_COMMONCRYPTO=1" \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DLIBTORRENT_SOURCE_DIR="$SRC" \
    -DBoost_INCLUDE_DIR="$BOOST_INCLUDE" \
    -DBoost_ROOT="$BOOST_ROOT_DIR" \
    -DBoost_NO_SYSTEM_PATHS=ON \
    -DCMAKE_DISABLE_FIND_PACKAGE_OpenSSL=ON \
    -DCMAKE_DISABLE_FIND_PACKAGE_GnuTLS=ON \
    -DCMAKE_DISABLE_FIND_PACKAGE_LibGcrypt=ON \
    -DCMAKE_DISABLE_FIND_PACKAGE_Iconv=ON \
    -DBUILD_SHARED_LIBS=OFF \
    -Dstatic_runtime=OFF \
    -Dencryption=ON \
    -Ddht=ON \
    -Dwebtorrent=OFF \
    -Di2p=OFF \
    -Dlogging=OFF \
    -Ddeprecated-functions=OFF \
    -Dbuild_tests=OFF -Dbuild_examples=OFF -Dbuild_tools=OFF -Dpython-bindings=OFF \
    > "$dir.configure.log" 2>&1 || { tail -40 "$dir.configure.log" >&2; exit 1; }

  cmake --build "$dir" --target BBTorrent torrent-rasterbar -- -j "$JOBS" > "$dir.build.log" 2>&1 \
    || { grep -E "error|Error" "$dir.build.log" | head -40 >&2; exit 1; }

  # One archive per slice: libtorrent + the wrapper. Debug info stripped.
  mkdir -p "$WORK/lib/$name"
  local out="$WORK/lib/$name/libTorrentEngine.a"
  libtool -static -no_warning_for_no_symbols -o "$out" \
    "$dir/libBBTorrent.a" "$dir/libtorrent/libtorrent-rasterbar.a"
  xcrun strip -S "$out" 2>/dev/null || true
}

# BLUEBOX_LIBTORRENT_SLICES="macos" rebuilds just some slices (the others are
# reused from an earlier run in $WORK).
SLICES="${BLUEBOX_LIBTORRENT_SLICES:-ios simulator macos}"
for slice in $SLICES; do
  case "$slice" in
    ios)       build_slice ios       iOS    iphoneos        "arm64"        "$IOS_MIN" ;;
    simulator) build_slice simulator iOS    iphonesimulator "arm64;x86_64" "$IOS_MIN" ;;
    macos)     build_slice macos     Darwin macosx          "arm64"        "$MACOS_MIN" ;;
    *) echo "error: unknown slice $slice" >&2; exit 2 ;;
  esac
done
for slice in ios simulator macos; do
  [ -f "$WORK/lib/$slice/libTorrentEngine.a" ] || { echo "error: slice $slice hasn't been built" >&2; exit 1; }
done

# --- Package -------------------------------------------------------------------

echo "==> Packaging $(basename "$OUTPUT")"
HEADERS="$WORK/headers"
rm -rf "$HEADERS"
mkdir -p "$HEADERS"
cp "$ENGINE/include/BBTorrent.h" "$ENGINE/include/module.modulemap" "$HEADERS/"

rm -rf "$OUTPUT"
xcodebuild -create-xcframework \
  -library "$WORK/lib/ios/libTorrentEngine.a" -headers "$HEADERS" \
  -library "$WORK/lib/simulator/libTorrentEngine.a" -headers "$HEADERS" \
  -library "$WORK/lib/macos/libTorrentEngine.a" -headers "$HEADERS" \
  -output "$OUTPUT" >/dev/null

echo "==> Done (libtorrent ${LIBTORRENT_VERSION})"
du -sh "$OUTPUT"/*/ | sed "s#$OUTPUT/##"
