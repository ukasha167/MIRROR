# scrcpy-server FLAG_SECURE Bypass Patch & Build System

This directory contains the custom patch and build automation for `scrcpy-server`, implementing the **3-Tier `FLAG_SECURE` Bypass Architecture** specified in `plan.md` Section 5.4.

---

## 1. Background: Why `FLAG_SECURE` Screens Turn Black on Android 12+

- **Android 11 and below:** `scrcpy-server` running under `com.android.shell` (`UID 2000`) called `SurfaceControl.createDisplay("scrcpy", true /* secure */)`. SurfaceFlinger composited all `FLAG_SECURE` layers (banking apps, 2FA authenticators, password managers, private chats) onto the capture display surface.
- **Android 12+ Security Restriction:** Google modified `SurfaceFlinger::createDisplay` in AOSP so that calling processes other than `AID_SYSTEM` (`UID 1000`) and `AID_ROOT` (`UID 0`) are forbidden from creating a display with `secure = true`. When `com.android.shell` (`UID 2000`) requests `secure = true`, SurfaceFlinger throws a `SecurityException`.
- **Stock scrcpy's Workaround:** In stock `scrcpy`, `ScreenCapture.java` checks `Build.VERSION.SDK_INT < AndroidVersions.API_30_ANDROID_11` and sets `secure = false` on Android 12+. As a result, SurfaceFlinger blanks out all `FLAG_SECURE` application windows, streaming only black pixels to the client.

---

## 2. The 3-Tier Bypass Architecture (plan.md Section 5.4)

| Tier | Device Setup | Mechanism | Capability |
| :--- | :--- | :--- | :--- |
| **Tier 1** | Rooted Phone (`su` / Magisk / KernelSU / APatch) | Launch `scrcpy-server` via `su -c app_process` (`UID 0`); pass `secure = true` to `SurfaceControl.createDisplay()`, and set virtual display flags `VIRTUAL_DISPLAY_FLAG_SECURE (1 << 2) \| VIRTUAL_DISPLAY_FLAG_SUPPORTS_PROTECTED_BUFFERS (1 << 5) \| VIRTUAL_DISPLAY_FLAG_TRUSTED (1 << 10)`. | **Full zero-latency video streaming** of software `FLAG_SECURE` content (banking, OTPs, password managers). |
| **Tier 2** | Android 12–16 with LSPosed / Zygisk | Companion Xposed hooks inside `system_server` (`UID 1000`):<br>1. Hook `WindowState.isSecureLocked()` &rarr; returns `false`.<br>2. Hook `WindowManagerService.notifyScreenshotListeners()` &rarr; returns empty list.<br>3. Hook `RecordingCallback` / `ActivityTaskManagerService` screen-recording listeners. | System-wide disablement of `FLAG_SECURE` and detection callbacks; works across stock and custom ROMs without modifying `scrcpy-server`. |
| **Tier 3** | Non-Root Devices (`shell` / `UID 2000`) | Input injection (`INJECT_TOUCH_EVENT` / `UHID`) remains functional even on blacked-out screens. Companion Accessibility Service provides wireframe bounding boxes and UI text hierarchy (`AccessibilityNodeInfo`) over the Mac mirror window. | Allows clicking and typing into protected security dialogs and confirmation screens without touching the physical phone. |

> **Note on Widevine L1 Hardware DRM:** Content protected by hardware TEE (Widevine L1 streams in Netflix, Disney+, Prime Video) is composited directly by the display hardware overlay without traversing normal system RAM. Even root cannot capture TEE buffers unless downgraded to Widevine L3 (software DRM).

---

## 3. Patch Details (`flag_secure_root.patch`)

The patch touches three files in `scrcpy/server`:

1. **`server/src/main/java/com/genymobile/scrcpy/wrappers/DisplayControl.java`**:
   - Adds `isRoot()` checking `android.os.Process.myUid() == 0`.
2. **`server/src/main/java/com/genymobile/scrcpy/video/ScreenCapture.java`**:
   - In `createDisplay()`: Enables `secure = true` when `DisplayControl.isRoot()` is true on Android 12+.
   - In `start(Surface surface)`: When `DisplayControl.isRoot()` is true, prioritizes the `SurfaceControl` API with `secure = true` instead of `DisplayManager.createVirtualDisplay` (which lacks secure flags in stock form), falling back to `DisplayManager` only if `SurfaceControl` fails.
3. **`server/src/main/java/com/genymobile/scrcpy/video/NewDisplayCapture.java`**:
   - Defines `VIRTUAL_DISPLAY_FLAG_SECURE = 1 << 2` and `VIRTUAL_DISPLAY_FLAG_SUPPORTS_PROTECTED_BUFFERS = 1 << 5`.
   - In `startNew(Surface surface)`: When `DisplayControl.isRoot()` is true, adds `VIRTUAL_DISPLAY_FLAG_SECURE | VIRTUAL_DISPLAY_FLAG_SUPPORTS_PROTECTED_BUFFERS | VIRTUAL_DISPLAY_FLAG_TRUSTED` to the virtual display flags.

---

## 4. Usage & Automation

Use `build_patched_server.sh` to check, apply, or build:

```bash
# Verify the patch applies cleanly against upstream scrcpy
./build_patched_server.sh --check

# Apply the patch to third_party/scrcpy
./build_patched_server.sh --apply

# Check patch status
./build_patched_server.sh --status

# Revert the patch
./build_patched_server.sh --revert

# Apply patch and compile scrcpy-server with Gradle
./build_patched_server.sh --build
```

When built, output binaries are placed in `build/scrcpy-server` and `build/scrcpy-server.jar`.
