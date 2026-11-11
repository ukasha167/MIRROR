#!/usr/bin/env bash
set -euo pipefail

# dev-status.sh: inspects monorepo status and component readiness.
# Supports optional --json flag for machine-readable automation.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

JSON_MODE=false
for arg in "$@"; do
    if [[ "$arg" == "--json" ]]; then
        JSON_MODE=true
    fi
done

# Rust Crates status
CRATES_EXPECTED=("continuity-core" "continuity-proto" "continuity-wireless" "continuity-usb" "continuity-scrcpy")
CRATES_FOUND=()
CRATES_MISSING=()

for crate in "${CRATES_EXPECTED[@]}"; do
    if [[ -f "crates/$crate/Cargo.toml" ]]; then
        CRATES_FOUND+=("$crate")
    else
        CRATES_MISSING+=("$crate")
    fi
done

# macOS Package status
MACOS_READY=false
if [[ -f "macos/Package.swift" ]]; then
    MACOS_READY=true
fi

# Android Project status
ANDROID_READY=false
if [[ -f "android/build.gradle.kts" || -f "android/build.gradle" || -f "android/settings.gradle.kts" || -f "android/settings.gradle" ]]; then
    ANDROID_READY=true
fi

# Third-party vendor status
VENDOR_MANIFEST=false
if [[ -f "third_party/MANIFEST.md" ]]; then
    VENDOR_MANIFEST=true
fi

VENDORS_EXPECTED=("NearDrop" "adb_client" "mtp-rs" "scrcpy" "cameraextension" "libASPL" "protocol")
VENDORS_FOUND=()
VENDORS_MISSING=()

for v in "${VENDORS_EXPECTED[@]}"; do
    if [[ -d "third_party/$v" ]]; then
        VENDORS_FOUND+=("$v")
    else
        VENDORS_MISSING+=("$v")
    fi
done

# Root files status
ROOT_FILES=("Cargo.toml" "Makefile" ".gitignore" "README.md" "AGENTS.md" "plan.md")
ROOT_PRESENT=()
for f in "${ROOT_FILES[@]}"; do
    if [[ -f "$f" ]]; then
        ROOT_PRESENT+=("$f")
    fi
done

format_json_array() {
    if [[ $# -eq 0 ]]; then
        echo ""
    else
        printf '"%s",' "$@" | sed 's/,$//'
    fi
}

if $JSON_MODE; then
    cat <<EOF
{
  "repository": "$REPO_ROOT",
  "root_files": [$(format_json_array ${ROOT_PRESENT[@]+"${ROOT_PRESENT[@]}"})],
  "crates": {
    "expected": [$(format_json_array ${CRATES_EXPECTED[@]+"${CRATES_EXPECTED[@]}"})],
    "found": [$(format_json_array ${CRATES_FOUND[@]+"${CRATES_FOUND[@]}"})],
    "missing": [$(format_json_array ${CRATES_MISSING[@]+"${CRATES_MISSING[@]}"})]
  },
  "macos": {
    "package_present": $MACOS_READY
  },
  "android": {
    "project_present": $ANDROID_READY
  },
  "third_party": {
    "manifest_present": $VENDOR_MANIFEST,
    "found": [$(format_json_array ${VENDORS_FOUND[@]+"${VENDORS_FOUND[@]}"})],
    "missing": [$(format_json_array ${VENDORS_MISSING[@]+"${VENDORS_MISSING[@]}"})]
  }
}
EOF
else
    echo "=== Mirror Monorepo Status ==="
    echo "Root Directory: $REPO_ROOT"
    echo ""
    echo "[Root Files] ${#ROOT_PRESENT[@]}/${#ROOT_FILES[@]} present"
    for f in "${ROOT_FILES[@]}"; do
        if [[ -f "$f" ]]; then
            echo "  + $f"
        else
            echo "  - $f (missing)"
        fi
    done
    echo ""
    echo "[Rust Crates] ${#CRATES_FOUND[@]}/${#CRATES_EXPECTED[@]} present"
    if [[ ${#CRATES_FOUND[@]} -gt 0 ]]; then
        for c in "${CRATES_FOUND[@]}"; do
            echo "  + crates/$c"
        done
    fi
    if [[ ${#CRATES_MISSING[@]} -gt 0 ]]; then
        for c in "${CRATES_MISSING[@]}"; do
            echo "  - crates/$c (pending)"
        done
    fi
    echo ""
    echo "[macOS Workspace]"
    if $MACOS_READY; then
        echo "  + macos/Package.swift present"
    else
        echo "  - macos/Package.swift (pending)"
    fi
    echo ""
    echo "[Android Workspace]"
    if $ANDROID_READY; then
        echo "  + android build configuration present"
    else
        echo "  - android build configuration (pending)"
    fi
    echo ""
    echo "[Upstream Vendors] ${#VENDORS_FOUND[@]}/${#VENDORS_EXPECTED[@]} cloned"
    if $VENDOR_MANIFEST; then
        echo "  + third_party/MANIFEST.md present"
    else
        echo "  - third_party/MANIFEST.md (pending)"
    fi
    if [[ ${#VENDORS_FOUND[@]} -gt 0 ]]; then
        for v in "${VENDORS_FOUND[@]}"; do
            echo "  + third_party/$v"
        done
    fi
    if [[ ${#VENDORS_MISSING[@]} -gt 0 ]]; then
        for v in "${VENDORS_MISSING[@]}"; do
            echo "  - third_party/$v (pending)"
        done
    fi
fi
