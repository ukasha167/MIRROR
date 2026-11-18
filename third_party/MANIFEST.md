# Third-Party Upstream Repositories Manifest

This manifest documents all vendored and reference repositories shallow-cloned in `/Users/develop/mirror/third_party/`, their license compliance audit, commit revisions, target crate/app references, and the exact files referenced by the `mirror` suite.

---

## 1. Compliance & Licensing Overview

The `mirror` project adheres strictly to **MIT** and **Apache-2.0** compatibility across all shared crates, macOS native targets, and Android native targets (per `AGENTS.md` and `plan.md` Section 9).

### License Audit Summary

| Repository | Upstream URL | SPDX License | Compatibility Verdict |
| :--- | :--- | :--- | :--- |
| **NearDrop** | `https://github.com/grishka/NearDrop.git` | `Unlicense` (Public Domain) | ✅ Fully permissive. Code ported/adapted into macOS Quick Share receiver. |
| **adb_client** | `https://github.com/cocool97/adb_client.git` | `MIT` | ✅ Fully permissive. Direct Rust dependency / reference for `continuity-usb`. |
| **mtp-rs** | `https://github.com/vdavid/mtp-rs.git` | `MIT OR Apache-2.0` | ✅ Fully permissive dual-license. Core USB MTP engine in `continuity-usb`. |
| **scrcpy** | `https://github.com/Genymobile/scrcpy.git` | `Apache-2.0` | ✅ Fully permissive. Server JAR bundled via `app_process`; protocol mirrored in `continuity-scrcpy`. |
| **cameraextension** | `https://github.com/ldenoue/cameraextension.git` | `MIT` | ✅ Fully permissive. Architectural foundation for `MirrorWebcamExtension` (`CMIOExtension`). |
| **libASPL** | `https://github.com/gavv/libASPL.git` | `MIT` | ✅ Fully permissive. CoreAudio HAL driver architecture for virtual microphone. |
| **protocol** | `https://github.com/localsend/protocol.git` | `Apache-2.0` | ✅ Fully permissive. Wire specification for `continuity-wireless`. |

### Prohibited Upstream Licenses (Do NOT Copy or Link Statically)

Per `AGENTS.md` and `plan.md` Section 9:
* **AGPL-3.0 (`EffortlessMetrics/SwiftMTP-dev`):** Do NOT copy code or headers into our workspace. Use MIT/Apache-2.0 `mtp-rs` instead.
* **GPL-2.0 / GPL-3.0 (`Martichou/rquickshare`, `KDE Connect`, `KonnectMac`, `BlackHole`, `LSPosed/DisableFlagSecure`):** Do NOT statically link or copy code into MIT/Apache crates or binaries. Use `NearDrop` (Unlicense) for Quick Share, `libASPL` (MIT) for virtual audio HAL, and maintain any LSPosed helper as an external standalone plugin.

---

## 2. Vendored Repositories Detail

### 2.1 grishka/NearDrop

- **Upstream:** `https://github.com/grishka/NearDrop.git`
- **Local Directory:** `third_party/NearDrop/`
- **SPDX License:** `Unlicense`
- **Commit SHA:** `add655c6c5a40b9ba03c0329b598f2817185f5a9`
- **Commit Date:** `2026-09-19 23:40:44 +0300` (Subject: *Bump version*)
- **Target Consuming Component:** `macos/NearDropReceiver/` and `crates/continuity-wireless/`
- **Exact Referenced Files:**
  - `NearbyShare/InboundNearbyConnection.swift`: Core state machine for incoming Quick Share connections, UKEY2 handshake handling, and file payload streaming.
  - `NearbyShare/NearbyConnectionManager.swift`: mDNS service registration (`_FC9F5ED42C8A._tcp.`) and TCP server socket listener on macOS.
  - `NearbyShare/NearbyConnection.swift`: Frame encryption/decryption using UKEY2 AES-GCM-256 session keys.
  - `NearbyShare/Protobuf/ukey.pb.swift`: Protocol Buffers schema for UKEY2 handshake messages (`Ukey2ClientInit`, `Ukey2ServerInit`, `Ukey2ClientFinish`).
  - `NearbyShare/Protobuf/wire_format.pb.swift`: Framing payload format for Offline Frame headers.
  - `NearbyShare/Protobuf/offline_wire_formats.pb.swift`: File metadata transfer formats (`ConnectionRequest`, `IntroductionFrame`).

---

### 2.2 cocool97/adb_client

- **Upstream:** `https://github.com/cocool97/adb_client.git`
- **Local Directory:** `third_party/adb_client/`
- **SPDX License:** `MIT`
- **Commit SHA:** `eb09aa54813bc8d5a7f2ecd8ad4da325b99e209d`
- **Commit Date:** `2026-10-30 18:54:15 +0100` (Subject: *fix: handle partial read in recv_file*)
- **Target Consuming Component:** `crates/continuity-usb/`
- **Exact Referenced Files:**
  - `adb_client/src/server_device/commands/sync/sync_session.rs`: ADB Sync v1/v2 file streaming session (`SEND`, `RECV`, `LIST`, `STAT`).
  - `adb_client/src/server_device/commands/sync/recv.rs`: Pull file transfer state machine and chunked reads.
  - `adb_client/src/server_device/commands/sync/stat.rs`: File metadata query (`STAT` and `LST2` v2 attributes).
  - `adb_client/src/server_device/commands/forward.rs`: Port forwarding command implementation (`tcp:PORT` to `localabstract:scrcpy`).
  - `adb_client/src/message_devices/adb_message_device.rs`: Low-level 24-byte ADB packet header parser and command multiplexer (`A_CNXN`, `A_OPEN`, `A_OKAY`, `A_CLSE`, `A_WRTE`).
  - `adb_client/src/message_devices/usb/usb_transport.rs`: Direct USB transfer implementation over USB bulk endpoints.

---

### 2.3 vdavid/mtp-rs

- **Upstream:** `https://github.com/vdavid/mtp-rs.git`
- **Local Directory:** `third_party/mtp-rs/`
- **SPDX License:** `MIT OR Apache-2.0`
- **Commit SHA:** `aed1138d33da5d6025fad2625432d39c3f8a321c`
- **Commit Date:** `2026-11-10 12:09:43 +0100` (Subject: *docs: Link the AOSP patches for the CopyObject handle bug (#59)...*)
- **Target Consuming Component:** `crates/continuity-usb/`
- **Exact Referenced Files:**
  - `crates/mtp-rs/src/ptp/container.rs`: 12-byte PTP/MTP container header serializer/deserializer (`length`, `type`, `code`, `transaction_id`).
  - `crates/mtp-rs/src/ptp/session/streaming.rs`: Pipelined streaming operations for high-throughput reads and writes.
  - `crates/mtp-rs/src/ptp/session/operations.rs`: MTP operations (`GetObject`, `SendObject`, `GetObjectInfo`, `GetStorageInfo`).
  - `crates/mtp-rs/src/transport/nusb.rs`: Async USB transport implementation using `kevinmehall/nusb`.
  - `crates/mtp-rs/src/transport/mock.rs`: In-memory mock transport used for deterministic hardware-free unit tests.

---

### 2.4 Genymobile/scrcpy

- **Upstream:** `https://github.com/Genymobile/scrcpy.git`
- **Local Directory:** `third_party/scrcpy/`
- **SPDX License:** `Apache-2.0`
- **Commit SHA:** `a60891aea193d92e7e5c3942700eca63f9d19a5f`
- **Commit Date:** `2026-10-08 08:41:27 +0200` (Subject: *Update links to 5.0.1*)
- **Target Consuming Component:** `crates/continuity-scrcpy/`, `third_party/scrcpy-server-patch/`, and `macos/MirrorRenderer/`
- **Exact Referenced Files:**
  - `server/src/main/java/com/genymobile/scrcpy/Server.java`: Entry point for `scrcpy-server.jar` when executed via `/system/bin/app_process`.
  - `server/src/main/java/com/genymobile/scrcpy/video/ScreenCapture.java`: SurfaceControl and VirtualDisplay screen capture pipeline (patched for root `FLAG_SECURE` bypass).
  - `server/src/main/java/com/genymobile/scrcpy/video/NewDisplayCapture.java`: Per-app independent virtual display creation with `--new-display` and `--flex-display`.
  - `server/src/main/java/com/genymobile/scrcpy/wrappers/SurfaceControl.java`: Reflection wrapper for Android hidden `android.view.SurfaceControl` methods.
  - `server/src/main/java/com/genymobile/scrcpy/wrappers/DisplayControl.java`: Android 14+ physical and virtual display control wrapper.
  - `server/src/main/java/com/genymobile/scrcpy/control/Controller.java`: UHID input events, touch, keyboard, and clipboard Binder listeners (`UID 2000`).

---

### 2.5 ldenoue/cameraextension

- **Upstream:** `https://github.com/ldenoue/cameraextension.git`
- **Local Directory:** `third_party/cameraextension/`
- **SPDX License:** `MIT`
- **Commit SHA:** `e1e97557d31cca8d3132676859bca84724b20d98`
- **Commit Date:** `2022-07-04 17:29:06 +0200` (Subject: *fixed bug in repeat interval of camera*)
- **Target Consuming Component:** `macos/MirrorWebcamExtension/`
- **Exact Referenced Files:**
  - `cameraextension/cameraextensionProvider.swift`: Implementation of `CMIOExtensionProviderSource`, `CMIOExtensionDeviceSource`, and `CMIOExtensionStreamSource`.
  - `cameraextension/main.swift`: Driver lifecycle, bundle entry point, and extension sink registration.
  - `samplecamera/ViewController.swift`: Client connection and frame enqueue logic.

---

### 2.6 gavv/libASPL

- **Upstream:** `https://github.com/gavv/libASPL.git`
- **Local Directory:** `third_party/libASPL/`
- **SPDX License:** `MIT`
- **Commit SHA:** `633e0f70203edd87d320fc5a3cae901e1363aac5`
- **Commit Date:** `2025-04-14 15:06:38 +0900` (Subject: *Remove broken link in README*)
- **Target Consuming Component:** `macos/` CoreAudio HAL audio extension (`MirrorAudioPlugin`)
- **Exact Referenced Files:**
  - `include/aspl/Driver.hpp`: High-level CoreAudio Audio Server Plugin (HAL) abstraction.
  - `include/aspl/Device.hpp`: Virtual audio device properties, sample rates, and channel layouts.
  - `include/aspl/Stream.hpp`: Audio stream management and ringbuffer transport.
  - `src/Driver.cpp`: CoreAudio factory registration and dispatch.
  - `src/Device.cpp`: Device control, volume curve, and IO operations.

---

### 2.7 localsend/protocol

- **Upstream:** `https://github.com/localsend/protocol.git`
- **Local Directory:** `third_party/protocol/`
- **SPDX License:** `Apache-2.0`
- **Commit SHA:** `62bd3406ec80d62f2ed46269cdc06c4dcc391083`
- **Commit Date:** `2026-08-08 00:23:57 +0200` (Subject: *add 2.2*)
- **Target Consuming Component:** `crates/continuity-wireless/`
- **Exact Referenced Files:**
  - `README.md`: LocalSend v2.1 protocol specification, UDP multicast discovery packet schema (`224.0.0.167:53317`), HTTP REST endpoints (`/api/localsend/v2/register`, `/api/localsend/v2/prepare-upload`, `/api/localsend/v2/upload`).
  - `v1.md`: LocalSend legacy v1 protocol reference.
  - `v3/`: LocalSend v3 draft specification.

---

## 3. Custom Server Patches

- **Directory:** `third_party/scrcpy-server-patch/`
  - `flag_secure_root.patch`: Unified diff patch implementing the Tier 1 `FLAG_SECURE` bypass:
    - Sets `secure = true` in `SurfaceControl.createDisplay()` when running as `UID 0` (`root` / `su`).
    - Prioritizes `SurfaceControl` with `secure = true` over unsecure `DisplayManager` when `UID 0` is active.
    - Adds `VIRTUAL_DISPLAY_FLAG_SECURE | VIRTUAL_DISPLAY_FLAG_SUPPORTS_PROTECTED_BUFFERS | VIRTUAL_DISPLAY_FLAG_TRUSTED` flags to `NewDisplayCapture.java` for virtual display sessions.
  - `build_patched_server.sh`: Shell automation to `--check`, `--apply`, `--revert`, and `--build` the patched `scrcpy-server`.
  - `README.md`: Architectural documentation for the 3-tier `FLAG_SECURE` bypass strategy.
