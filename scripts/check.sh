#!/usr/bin/env bash
set -euo pipefail

# check.sh: Unified check and verification runner for the mirror monorepo.
# Usage:
#   ./scripts/check.sh [all|rust|macos|vendor|test|test-rust|test-macos|syntax]

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

MODE="${1:-all}"
FAILED=0

log_ok() {
    printf "\033[0;32m[OK]\033[0m %s\n" "$1"
}

log_warn() {
    printf "\033[0;33m[WARN]\033[0m %s\n" "$1"
}

log_fail() {
    printf "\033[0;31m[FAIL]\033[0m %s\n" "$1"
}

log_info() {
    printf "\033[0;34m[INFO]\033[0m %s\n" "$1"
}

check_syntax() {
    log_info "Checking shell scripts syntax..."
    local script_fail=0
    for s in "$REPO_ROOT"/scripts/*.sh; do
        if [[ -f "$s" ]]; then
            if bash -n "$s"; then
                log_ok "Syntax valid: $(basename "$s")"
            else
                log_fail "Syntax error: $(basename "$s")"
                script_fail=1
            fi
        fi
    done
    return $script_fail
}

check_rust() {
    log_info "Running cargo check on Rust workspace..."
    if ! command -v cargo >/dev/null 2>&1; then
        log_fail "cargo is not installed or not in PATH"
        return 1
    fi

    # Check if there are any crates with Cargo.toml
    local crate_count
    crate_count=$(find "$REPO_ROOT/crates" -mindepth 2 -maxdepth 2 -name "Cargo.toml" 2>/dev/null | wc -l | tr -d ' ')

    if [[ "$crate_count" -eq 0 ]]; then
        log_warn "No Rust crates found in crates/ yet"
        return 0
    fi

    if cargo check --workspace; then
        log_ok "cargo check passed for workspace ($crate_count crates)"
    else
        log_fail "cargo check failed"
        return 1
    fi
}

test_rust() {
    log_info "Running cargo test on Rust workspace..."
    if ! command -v cargo >/dev/null 2>&1; then
        log_fail "cargo is not installed or not in PATH"
        return 1
    fi

    local crate_count
    crate_count=$(find "$REPO_ROOT/crates" -mindepth 2 -maxdepth 2 -name "Cargo.toml" 2>/dev/null | wc -l | tr -d ' ')

    if [[ "$crate_count" -eq 0 ]]; then
        log_warn "No Rust crates found in crates/ to test"
        return 0
    fi

    if cargo test --workspace; then
        log_ok "cargo test passed for workspace ($crate_count crates)"
    else
        log_fail "cargo test failed"
        return 1
    fi
}

check_macos() {
    log_info "Checking macOS Swift package..."
    if [[ ! -f "$REPO_ROOT/macos/Package.swift" ]]; then
        log_warn "macos/Package.swift does not exist yet (skipping)"
        return 0
    fi

    if ! command -v swift >/dev/null 2>&1; then
        log_fail "swift is not installed or not in PATH"
        return 1
    fi

    if swift build --package-path "$REPO_ROOT/macos"; then
        log_ok "swift build passed for macos/"
    else
        log_fail "swift build failed for macos/"
        return 1
    fi
}

test_macos() {
    log_info "Testing macOS Swift package..."
    if [[ ! -f "$REPO_ROOT/macos/Package.swift" ]]; then
        log_warn "macos/Package.swift does not exist yet (skipping)"
        return 0
    fi

    if ! command -v swift >/dev/null 2>&1; then
        log_fail "swift is not installed or not in PATH"
        return 1
    fi

    if swift test --package-path "$REPO_ROOT/macos"; then
        log_ok "swift test passed for macos/"
    else
        log_fail "swift test failed for macos/"
        return 1
    fi
}

vendor_status() {
    log_info "Checking third_party vendor status..."
    local expected=("NearDrop" "adb_client" "mtp-rs" "scrcpy" "cameraextension" "libASPL" "protocol")
    local found=0
    local missing=0

    if [[ -f "$REPO_ROOT/third_party/MANIFEST.md" ]]; then
        log_ok "third_party/MANIFEST.md is present"
    else
        log_warn "third_party/MANIFEST.md is not present"
    fi

    for v in "${expected[@]}"; do
        if [[ -d "$REPO_ROOT/third_party/$v" ]]; then
            log_ok "Vendored repository found: third_party/$v"
            ((found++))
        else
            log_warn "Vendored repository pending: third_party/$v"
            ((missing++))
        fi
    done

    echo "Vendor Summary: $found found, $missing pending"
}

case "$MODE" in
    syntax)
        check_syntax || FAILED=1
        ;;
    rust)
        check_rust || FAILED=1
        ;;
    test-rust)
        test_rust || FAILED=1
        ;;
    macos)
        check_macos || FAILED=1
        ;;
    test-macos)
        test_macos || FAILED=1
        ;;
    vendor)
        vendor_status
        ;;
    test)
        test_rust || FAILED=1
        if [[ -f "$REPO_ROOT/macos/Package.swift" ]]; then
            test_macos || FAILED=1
        fi
        ;;
    all)
        check_syntax || FAILED=1
        check_rust || FAILED=1
        if [[ -f "$REPO_ROOT/macos/Package.swift" ]]; then
            check_macos || FAILED=1
        fi
        vendor_status
        ;;
    *)
        echo "Usage: $0 [all|rust|macos|vendor|test|test-rust|test-macos|syntax]"
        exit 1
        ;;
esac

exit $FAILED
