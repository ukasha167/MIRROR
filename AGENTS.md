# Agent workflow and engineering guide

This repository builds the Android and macOS continuity suite described in `plan.md`. Every coordinator and subagent working in this repository must follow the model routing rules, file ownership rules, and engineering standards below.

## Model routing and quota management

Always pick the lowest-cost model tier that fits the task so rate limits stay low. Split work across non-overlapping directories and run independent tasks in parallel.

### Gemini harness routing

| Tier | Model ID | Effort | Assigned tasks |
| :--- | :--- | :--- | :--- |
| Tier 1 | `gemini-3.8-flash-high` | High | Project scaffolding, directory creation, cloning and vendoring upstream repositories, build configuration (`Cargo.toml`, `Package.swift`, Gradle files, `Makefile`), simple wiring, formatting, and stall monitoring. |
| Tier 2 | `gemini-4-argon-medium` | Medium | Feature implementation across Rust crates, Swift UI views, and Kotlin services, wire protocol parsers and serializers, state machines, mock transports, and unit or integration tests. |
| Tier 3 | `gemini-4-argon-high` | High | High-complexity systems code (zero-copy `VTDecompressionSession` to `IOSurface` to `CAMetalLayer` and `CMIOExtension`, `FSKit` volume lifecycles, pipelined USB/ADB/MTP concurrency, `FLAG_SECURE` root and Binder patches, mTLS and Noise cryptography), cross-module debugging, and all architecture or code reviews. |

### Claude harness routing

| Tier | Model family | Effort | Assigned tasks |
| :--- | :--- | :--- | :--- |
| Tier 1 | Haiku (`claude-haiku`) | High | Project scaffolding, cloning and vendoring upstream repositories, build configuration, simple wiring, and boilerplate generation. (If Haiku is unavailable in the active roster, fall back to `claude-sonnet-5-5-low`.) |
| Tier 2 | Sonnet (`claude-sonnet-5-5-medium`) | Medium | Medium-complexity coding across Rust crates, Swift targets, and Android modules, protocol handlers, UI components, and test suites. |
| Tier 3 | Opus (`claude-opus-5-5-high`) | High | High-complexity systems code, zero-copy media and USB pipelines, cryptographic pairing, `FLAG_SECURE` bypass internals, and code or architecture reviews. |

## Swarm and subagent rules

1. **One owner per directory.** Never assign two active workers to edit the same file or crate at the same time. Each worker brief must list the exact paths it may write and the paths it must not touch.
2. **Author and verifier separation.** Authors write code and tests within their assigned directory. Verifiers (Tier 3) inspect diffs, run test suites, and report defects back to the author by name on the board without editing the author's files.
3. **Reference board history by sequence number.** On the swarm board, refer to earlier posts as `#4` or `#7` instead of copying reports between messages.
4. **Quota fallback.** If a model runs out of quota mid-task, switch the waiting worker to the active fallback tier with `swarm{action:"model"}` instead of killing and recreating the worker.

## Monorepo directory ownership map

```text
mirror/
├── AGENTS.md                       # Coordinator governance and routing rules
├── CLAUDE.md                       # Pointer to AGENTS.md for Claude harnesses
├── plan.md                         # Architecture specification
├── Cargo.toml                      # Root Rust workspace (owned by scaffold-rust)
├── Makefile                        # Unified build and check entrypoints (owned by scaffold-rust)
├── scripts/                        # Developer and agent check scripts (owned by scaffold-rust)
├── crates/
│   ├── continuity-core/            # UniFFI facade, pairing state machine, Keychain/Keystore traits (owned by proto-coder)
│   ├── continuity-proto/           # mTLS (rustls), Noise_XX pairing, control packet multiplexer (owned by proto-coder)
│   ├── continuity-wireless/        # LocalSend v2.1 engine, 4-stream parallel TCP, tar streaming, mDNS (owned by wireless-coder)
│   ├── continuity-usb/             # ADB client (Burst Mode + Sync v2 LZ4) + mtp-rs pipelined USB (owned by usb-coder)
│   └── continuity-scrcpy/          # scrcpy socket handshake, 12B frame demuxer, UHID/Touch/Clip serializer (owned by scrcpy-coder)
├── third_party/                    # Shallow clones and license manifest of upstream reference repos (owned by vendor)
├── macos/                          # Swift 6 package and Xcode targets for macOS 15-26 arm64 (owned by scaffold-macos)
└── android/                        # Gradle Kotlin 2.x and Jetpack Compose modules for Android 12-17 (owned by scaffold-android)
```

## User experience (UX) requirements

* **Native OS integration.** Use AppKit (`NSPanel`, `NSVisualEffectView`, `MenuBarExtra`) and SwiftUI on macOS, and Material 3 Jetpack Compose on Android. Expose the Mac directly in Android's native Quick Share sheet (via the embedded NearDrop receiver) and mount phone storage in the macOS Finder sidebar (via `FSKit`).
* **Zero-prompt continuity for paired devices.** Once two devices complete QR or PIN pairing and pin each other's TLS certificates in Keychain and Android Keystore, file drops, clipboard sync, and 2FA OTP notifications run without confirmation dialogs.
* **Hardware resource limits.** Keep macOS idle RAM below 28 MB and idle CPU/GPU at 0.0%. Decode mirroring and camera streams with hardware H.265 (`VTDecompressionSession` into `IOSurface` and `CAMetalLayer`) to stay below 2.5% CPU at 1080p60 on Apple M1. Never default to AV1 on M1 or M2 Macs because those chips lack hardware AV1 decoders.
* **Android battery protection.** Hold zero wakelocks and zero persistent TCP loops when away from the Mac. Wake the app through `CompanionDeviceService` presence callbacks and Android 14+ hardware-offloaded `NsdManager.registerServiceInfoCallback`. Turn off the physical OLED panel (`SurfaceControl.setDisplayPowerMode`) during screen mirroring when requested.

## Developer experience (DX) requirements

* **Hardware-free testability.** Every Rust crate, Swift target, and Kotlin module must compile and pass unit tests without an Android phone connected over USB or Wi-Fi. Abstract USB bulk endpoints, ADB sockets, and LAN streams behind traits with deterministic in-memory loopback implementations.
* **One-command verification.** Running `cargo test --workspace` at the repository root must execute all Rust unit and integration tests cleanly. Running `swift test` in `macos/` must verify macOS modules.
* **License hygiene.** Keep all code inside `crates/`, `macos/`, and `android/` compatible with MIT and Apache-2.0 licensing. Use `localsend` (Apache-2.0), `NearDrop` (Unlicense), `adb_client` (MIT), `mtp-rs` (MIT/Apache-2.0), `scrcpy` (Apache-2.0), `cameraextension` (MIT), and `libASPL` (MIT). Never copy code from AGPL (`EffortlessMetrics/SwiftMTP-dev`) or GPL (`rquickshare`, `KDE Connect`, `BlackHole`, `LSPosed/DisableFlagSecure`) repositories into our source tree.

## Agent experience (AX) requirements

* **Small, modular files.** Keep individual source files under 350 lines. Separate wire format definitions (`packet.rs` or `wire.rs`), state machines (`session.rs` or `engine.rs`), transport traits (`transport.rs`), and error types (`error.rs`).
* **Typed errors with context.** Use `thiserror` in Rust library crates and never call `.unwrap()` or `.expect()` on untrusted network, USB, or socket inputs. Include packet type, expected length, and actual length in error variants so agents can diagnose protocol bugs from test output alone.
* **Explicit byte-layout docstrings.** Document every binary header (such as the 12-byte `scrcpy` frame header, 24-byte ADB message header, and 12-byte MTP container header) with exact byte offsets and endianness directly above the parser function.
* **Isolated crate checks.** Design each crate in `crates/` so an agent can run `cargo test -p <crate-name>` in a few seconds without waiting on native UI builds.
