.POSIX:
.PHONY: all check test test-rust test-macos vendor-status dev-status dev-status-json clean help scrcpy-server neardrop phone-check

SHELL := /bin/bash

all: check

check:
	@./scripts/check.sh all

test:
	@./scripts/check.sh test

test-rust:
	@./scripts/check.sh test-rust

test-macos:
	@./scripts/check.sh test-macos

vendor-status:
	@./scripts/check.sh vendor

dev-status:
	@./scripts/dev-status.sh

dev-status-json:
	@./scripts/dev-status.sh --json

scrcpy-server:
	@./scripts/build-scrcpy-server.sh

neardrop:
	@./scripts/build-neardrop.sh

# Needs a phone on USB or saved Wi-Fi. Touches the phone clipboard, not the Mac pasteboard.
phone-check: scrcpy-server
	@cd macos && swift build --product mirror-desk >/dev/null && .build/debug/mirror-desk locate && .build/debug/mirror-desk clipboard-roundtrip

clean:
	@echo "Cleaning build artifacts..."
	@cargo clean 2>/dev/null || true
	@if [ -d macos/.build ]; then rm -rf macos/.build; fi

help:
	@echo "Mirror Monorepo Build and Verification Entrypoints"
	@echo ""
	@echo "Targets:"
	@echo "  make check           Run full repo checks (shell syntax, rust, macos, vendor)"
	@echo "  make test            Run all automated test suites across components"
	@echo "  make test-rust       Run cargo test --workspace"
	@echo "  make scrcpy-server   Build patched scrcpy-server into build/"
	@echo "  make neardrop        Build NearDrop.app into build/NearDrop/"
	@echo "  make phone-check     Scripted checks against a connected phone"
	@echo "  make test-macos      Run swift test inside macos/"
	@echo "  make vendor-status   Report shallow clone status of third_party repositories"
	@echo "  make dev-status      Display high-level status of monorepo subprojects"
	@echo "  make dev-status-json Output dev status in JSON for automated tooling"
	@echo "  make clean           Clean cargo target and Swift build artifacts"
	@echo "  make help            Display this help message"
