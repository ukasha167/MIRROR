#!/usr/bin/env bash
# Builds NearDrop (Quick Share receiver, Unlicense) from third_party/NearDrop, ad-hoc signed.
# Output: build/NearDrop/NearDrop.app. Copy it to /Applications to keep it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED="$ROOT/build/NearDrop-derived"
OUT="$ROOT/build/NearDrop"

xcodebuild -quiet \
    -project "$ROOT/third_party/NearDrop/NearDrop.xcodeproj" \
    -scheme NearDrop -configuration Release \
    -destination "platform=macOS,arch=$(uname -m)" \
    -derivedDataPath "$DERIVED" \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
    build

rm -rf "$OUT"
mkdir -p "$OUT"
cp -R "$DERIVED/Build/Products/Release/NearDrop.app" "$OUT/"
echo "built $OUT/NearDrop.app"
