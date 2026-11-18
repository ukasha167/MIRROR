#!/usr/bin/env bash
# Builds scrcpy-server from upstream source with our patches applied.
#
# The server version must match the scrcpy client on this Mac, or the client
# refuses the connection. SCRCPY_VERSION defaults to the version of the
# `scrcpy` binary on PATH, so the two stay pinned together.
#
# Output: build/scrcpy-server-v<version> (a jar without the .jar suffix, the
# name scrcpy expects for SCRCPY_SERVER_PATH).
#
# Usage:
#   scripts/build-scrcpy-server.sh            build for the installed client
#   SCRCPY_VERSION=4.1 scripts/build-scrcpy-server.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -z "${SCRCPY_VERSION:-}" ]]; then
    if ! command -v scrcpy >/dev/null; then
        echo "error: scrcpy not on PATH; install it (brew install scrcpy) or set SCRCPY_VERSION" >&2
        exit 1
    fi
    SCRCPY_VERSION="$(scrcpy --version | head -1 | awk '{print $2}')"
fi

PATCH_DIR="$ROOT/patches/scrcpy-v$SCRCPY_VERSION"
SRC_DIR="$ROOT/build/scrcpy-v$SCRCPY_VERSION"
OUT="$ROOT/build/scrcpy-server-v$SCRCPY_VERSION"

if [[ ! -d "$PATCH_DIR" ]]; then
    echo "error: no patches for scrcpy $SCRCPY_VERSION in $PATCH_DIR" >&2
    echo "Rebase patches/ onto that version, or install the client version that has patches." >&2
    exit 1
fi

export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
if [[ ! -d "$ANDROID_HOME" ]]; then
    echo "error: Android SDK not found at $ANDROID_HOME" >&2
    exit 1
fi

# Fresh checkout every time, so a half-applied patch never leaks into a build.
rm -rf "$SRC_DIR"
git clone --quiet --depth 1 --branch "v$SCRCPY_VERSION" \
    https://github.com/Genymobile/scrcpy.git "$SRC_DIR" 2>/dev/null

for patch in "$PATCH_DIR"/*.patch; do
    echo "applying $(basename "$patch")"
    git -C "$SRC_DIR" apply "$patch"
done

BUILD_DIR="$SRC_DIR/build-server"
mkdir -p "$BUILD_DIR"
(cd "$SRC_DIR" && BUILD_DIR="$BUILD_DIR" ./server/build_without_gradle.sh >/dev/null)

cp "$BUILD_DIR/scrcpy-server" "$OUT"
echo "built $OUT"
