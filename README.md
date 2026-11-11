# Mirror

Mirror is an Android and macOS continuity suite. It provides wireless file transfer, USB file transfer over ADB and MTP, low-latency screen mirroring with the scrcpy protocol, clipboard synchronization, and phone camera and microphone streaming via CoreMediaIO and CoreAudio.

## Architecture

The system consists of three main platform targets and a shared systems core:

- Shared core (`crates/`): Written in Rust. Implements wire protocols, TLS and Noise encryption handshakes, LocalSend file transfers, ADB client commands, MTP file operations, and scrcpy frame demuxing. Exposed to native UI layers through Mozilla UniFFI.
- macOS app (`macos/`): Written in Swift 6. Provides native AppKit and SwiftUI interfaces, hardware H.265 video decoding via VideoToolbox and Metal, Finder sidebar volume mounts via FSKit, and virtual webcam feeds via CoreMediaIO.
- Android app (`android/`): Written in Kotlin and Jetpack Compose. Provides Material 3 interfaces, background presence monitoring via CompanionDeviceService, notification forwarding, and privileged Binder interfaces.
- Third-party references (`third_party/`): Vendored reference repositories under permissive open-source licenses (MIT, Apache-2.0, and Unlicense).

## Directory layout

```text
mirror/
├── Cargo.toml               Rust workspace manifest
├── Makefile                 Build and verification targets
├── README.md                Project documentation
├── AGENTS.md                Agent governance and routing rules
├── plan.md                  Architecture specification
├── scripts/                 Automation and check scripts
│   ├── check.sh             Verification runner
│   └── dev-status.sh        Component status reporter
├── crates/                  Shared Rust crates
│   ├── continuity-core      UniFFI bridge and pairing state machine
│   ├── continuity-proto     TLS, Noise_XX, and packet multiplexing
│   ├── continuity-wireless  LocalSend protocol and parallel TCP engine
│   ├── continuity-usb       ADB burst mode client and MTP initiator
│   └── continuity-scrcpy    scrcpy protocol parser and demuxer
├── macos/                   macOS Swift 6 package and Xcode targets
├── android/                 Android Gradle and Jetpack Compose modules
└── third_party/             Vendored upstream reference projects
```

## Prerequisites

To build and run tests across the workspace, install:

1. Rust toolchain (stable, 2021 edition or newer):
   `rustup default stable`
2. Apple Swift toolchain (Swift 6 or newer on macOS 15+):
   `xcode-select --install`
3. GNU Make or BSD Make (`make`)

## Commands

Use the Makefile targets for common tasks:

- `make check`: Run all repository checks (shell syntax, Rust workspace check, macOS package build, vendor status).
- `make test`: Run all unit and integration tests across Rust and Swift.
- `make test-rust`: Run `cargo test --workspace`.
- `make test-macos`: Run `swift test` inside `macos/`.
- `make vendor-status`: Inspect status of upstream reference clones in `third_party/`.
- `make dev-status`: Display component readiness across crates, macos, android, and third_party.
- `make dev-status-json`: Output status in JSON format for automated tooling.
- `make clean`: Remove Cargo and Swift build directories.

## Subsystems

### Wireless file transfer
Uses the LocalSend v2.1 protocol over local Wi-Fi with mutual TLS. Paired devices pin certificate fingerprints to avoid confirmation dialogs on every transfer. Incorporates an embedded Quick Share receiver so Android devices can share directly from the native system share sheet.

### Wired USB transfer
Uses a two-tier approach. When USB debugging is active, the pure-Rust ADB client transfers files using Sync v2 with LZ4 compression and ADB burst mode over parallel multiplexed channels. When USB debugging is inactive, the pure-Rust MTP initiator manages file transfers over pipelined bulk USB endpoints. Connected storage appears directly in the macOS Finder sidebar through an FSKit volume extension.

### Screen mirroring and app streaming
Uses `scrcpy-server` executed on the Android device. The native macOS client decodes hardware H.265 streams via VideoToolbox into IOSurface buffers, which are presented directly by Metal without intermediate CPU copies. Supports independent virtual displays for running individual phone apps in separate macOS windows.

### Continuity and clipboard
Synchronizes clipboard text and images between macOS and Android. Text synchronizes over the encrypted control channel in under 15 milliseconds. Large images and files use lazy promises on macOS (`NSPasteboardItemDataProvider`) so payload bytes transfer only when the user pastes.

### Continuity camera and microphone
Feeds phone camera frames into a macOS CoreMediaIO Camera Extension (`CMIOExtension`) and microphone audio into a CoreAudio plug-in. macOS video effects such as Portrait blur and Studio Light function with the stream. The phone camera starts only when a Mac application opens the camera stream and shuts down when the session ends.

## License

Code authored in this repository is licensed under the MIT License or the Apache License, Version 2.0.
