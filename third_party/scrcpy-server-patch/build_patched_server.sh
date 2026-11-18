#!/usr/bin/env bash
# ==============================================================================
# build_patched_server.sh
# 
# Builds a patched scrcpy-server.jar with Tier 1 FLAG_SECURE root bypass support:
# 1. SurfaceControl.createDisplay("scrcpy", true) when UID 0 (root / su) is active.
# 2. VirtualDisplay flags:
#    VIRTUAL_DISPLAY_FLAG_SECURE (1 << 2) |
#    VIRTUAL_DISPLAY_FLAG_SUPPORTS_PROTECTED_BUFFERS (1 << 5) |
#    VIRTUAL_DISPLAY_FLAG_TRUSTED (1 << 10)
#
# See plan.md Section 5.4 for complete architectural details.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRCPY_DIR="${SCRCPY_DIR:-"$(cd "$SCRIPT_DIR/../scrcpy" && pwd)"}"
PATCH_FILE="$SCRIPT_DIR/flag_secure_root.patch"
OUT_DIR="$SCRIPT_DIR/build"

usage() {
    cat <<EOF
Usage: $(basename "$0") [COMMAND]

Commands:
  --check     Check if flag_secure_root.patch applies cleanly to scrcpy
  --apply     Apply flag_secure_root.patch to scrcpy repository
  --revert    Revert flag_secure_root.patch from scrcpy repository
  --build     Apply patch and build scrcpy-server with Gradle
  --status    Show patch status against scrcpy repository
  --help      Show this help message

Environment variables:
  SCRCPY_DIR  Path to scrcpy repository (default: $SCRCPY_DIR)
  GRADLE      Path to gradle / gradlew (default: \$SCRCPY_DIR/gradlew)
EOF
}

check_scrcpy_dir() {
    if [[ ! -d "$SCRCPY_DIR" || ! -f "$SCRCPY_DIR/server/build.gradle" ]]; then
        echo "Error: scrcpy repository not found at '$SCRCPY_DIR'." >&2
        exit 1
    fi
}

is_patch_applied() {
    # Check if patch is already applied in reverse
    git -C "$SCRCPY_DIR" apply --reverse --check "$PATCH_FILE" >/dev/null 2>&1
}

do_check() {
    check_scrcpy_dir
    if is_patch_applied; then
        echo "[INFO] Patch 'flag_secure_root.patch' is ALREADY applied in '$SCRCPY_DIR'."
        return 0
    fi

    if git -C "$SCRCPY_DIR" apply --check "$PATCH_FILE"; then
        echo "[OK] Patch 'flag_secure_root.patch' can be applied cleanly."
        return 0
    else
        echo "[ERROR] Patch 'flag_secure_root.patch' does NOT apply cleanly." >&2
        return 1
    fi
}

do_apply() {
    check_scrcpy_dir
    if is_patch_applied; then
        echo "[INFO] Patch is already applied."
        return 0
    fi

    echo "[INFO] Applying flag_secure_root.patch..."
    git -C "$SCRCPY_DIR" apply "$PATCH_FILE"
    echo "[OK] Patch applied successfully."
}

do_revert() {
    check_scrcpy_dir
    if ! is_patch_applied; then
        echo "[INFO] Patch is not currently applied."
        return 0
    fi

    echo "[INFO] Reverting flag_secure_root.patch..."
    git -C "$SCRCPY_DIR" apply --reverse "$PATCH_FILE"
    echo "[OK] Patch reverted successfully."
}

do_status() {
    check_scrcpy_dir
    if is_patch_applied; then
        echo "Status: APPLIED"
    else
        echo "Status: NOT_APPLIED"
    fi
    git -C "$SCRCPY_DIR" status --short "server/"
}

do_build() {
    check_scrcpy_dir
    do_apply

    GRADLE="${GRADLE:-"$SCRCPY_DIR/gradlew"}"
    if [[ ! -x "$GRADLE" ]]; then
        chmod +x "$GRADLE" 2>/dev/null || true
    fi

    if [[ -z "${ANDROID_HOME:-}" && -z "${ANDROID_SDK_ROOT:-}" ]]; then
        echo "[WARNING] Neither ANDROID_HOME nor ANDROID_SDK_ROOT is set in environment."
        echo "[WARNING] If Gradle build fails, export ANDROID_HOME=/path/to/android/sdk"
    fi

    echo "[INFO] Building scrcpy-server with Gradle..."
    mkdir -p "$OUT_DIR"

    (
        cd "$SCRCPY_DIR"
        "$GRADLE" :server:assembleRelease
    )

    APK_OUT="$SCRCPY_DIR/server/build/outputs/apk/release/server-release-unsigned.apk"
    if [[ -f "$APK_OUT" ]]; then
        cp "$APK_OUT" "$OUT_DIR/scrcpy-server"
        cp "$APK_OUT" "$OUT_DIR/scrcpy-server.jar"
        echo "[OK] Patched scrcpy-server built successfully:"
        echo "     $OUT_DIR/scrcpy-server"
        echo "     $OUT_DIR/scrcpy-server.jar"
        ls -la "$OUT_DIR/scrcpy-server"
    else
        echo "[ERROR] Build completed but output APK was not found at expected path: $APK_OUT" >&2
        exit 1
    fi
}

CMD="${1:---build}"

case "$CMD" in
    --check)
        do_check
        ;;
    --apply)
        do_apply
        ;;
    --revert)
        do_revert
        ;;
    --status)
        do_status
        ;;
    --build)
        do_build
        ;;
    --help|-h)
        usage
        ;;
    *)
        echo "Unknown option: $CMD" >&2
        usage >&2
        exit 1
        ;;
esac
