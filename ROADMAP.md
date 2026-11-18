# Mirror roadmap

This file replaces `plan.md` as the working plan. It starts from tests run on 2026-11-18 against a Pixel 7 Pro on Android 17 (SDK 37, `user` build, not rooted) and a MacBook Air on macOS 26.

## What the first version actually does

| Part | Builds | Tests | Works end to end |
| --- | --- | --- | --- |
| Rust crates (`crates/`) | yes | all pass | no. No app links them. They are dead code. |
| macOS app (`macos/`) | yes | 23 pass | partly. Menu bar app starts and listens on TCP 53318. |
| Android app (`android/`) | yes (100 MB debug APK) | pass | no. With the Mac app running over USB it shows "Not Connected" and asks for a manual pairing code. |
| Quick Share receiver (`macos/Sources/NearDropReceiver`) | yes | pass | not tested. It is a 113-line rewrite of NearDrop's UKEY2 code, not NearDrop itself. |

The earlier plan chose libraries by license (MIT/Apache only) and reimplemented protocols that mature projects already ship. The license rule no longer applies, so the new plan reuses those projects directly.

## Test results that shape the plan

All tests used upstream scrcpy 4.1 from Homebrew, plus a two-change patch to its server (`patches/scrcpy-v4.1/0001-desk-mode-virtual-display.patch`).

1. **Mirroring with the phone's panel off works.** `scrcpy --turn-screen-off` reported "Device display turned off" and kept streaming on Android 17. The phone has to stay unlocked; pressing the power button locks it and ends the useful session.
2. **Desk mode works with the phone locked.** With the patch, `scrcpy --new-display=1600x1000/200` creates a second screen that stays awake and unlocked while the phone's own screen is locked and dozing. Settings, Clock and Chrome all opened and drew in their tablet layouts on that screen after the phone locked. Android 17 also draws a desktop taskbar on it.
   - Why upstream fails: on Android 14+ scrcpy adds `VIRTUAL_DISPLAY_FLAG_DEVICE_DISPLAY_GROUP`, which ties the virtual screen to the phone's sleep state. The phone locks and the virtual screen powers off about 7 seconds later.
   - Patch part 1: drop that flag. The screen gets its own power group (`groupId=1`).
   - Patch part 2: the own group still sleeps after 10 idle seconds while the keyguard shows. A thread calls `IPowerManager.userActivity(displayId)` every 4 seconds. The shell user holds `DEVICE_POWER`, `ADD_TRUSTED_DISPLAY` and `ADD_ALWAYS_UNLOCKED_DISPLAY`, so no root is needed.
3. **FLAG_SECURE cannot be bypassed system-wide without root on this phone.** A Chrome incognito tab (which sets FLAG_SECURE) recorded as solid black on both the main screen and the virtual screen. The shell user lacks `CAPTURE_SECURE_VIDEO_OUTPUT`. Android 17 has a `disable_secure_windows` switch, but it only takes effect on debuggable builds (`ro.debuggable=0` here).
4. **Wi-Fi without a cable works after one USB session.** `adb tcpip 5555` then `adb connect <phone-ip>:5555` connected with no prompt, using the key the Mac already authorized over USB. This mode resets when the phone reboots. Android's newer "Wireless debugging" toggle needs an on-screen approval per Wi-Fi network, so it cannot be turned on while the phone is locked.
5. **Clipboard needs our own client.** scrcpy sends the Mac clipboard to the phone only when you press Cmd+V in its window. Phone-to-Mac sync did not arrive in three runs. The shell user holds `READ_CLIPBOARD_IN_BACKGROUND`, so a server-side poll of `getPrimaryClip()` is the fallback if the listener stays silent.

## Ways to use the phone with its screen off

Ranked best first.

1. **Desk mode (tested, works).** Patched scrcpy virtual display, sized to a Mac window. The phone stays locked, its panel off. Apps run on the virtual screen. A stranger who picks up the phone sees the lock screen.
2. **Panel-off mirror (tested, works).** Mirror the real screen with `--turn-screen-off`. Apps keep their phone layout. The phone must stay unlocked, so anyone holding it can use it. Set screen timeout long (scrcpy `--screen-off-timeout`) so it does not lock mid-session.
3. **Unlock help for mode 2.** Add the Mac as a Bluetooth trusted device under Extend Unlock so the phone stays unlocked while the Mac is near. Not tested yet.
4. **Battery.** Leave the phone on a charger for long sessions. With the panel off the encoder is the main cost.

Limits to accept: FLAG_SECURE apps (most banking apps, Wallet card details, incognito tabs) show black in every mode. Per-app workaround without root: repackage the app with LSPatch or its NPatch fork plus a DisableFlagSecure module. Apps with Play Integrity checks refuse to run after repackaging.

## Projects to build on

| Need | Project | How we use it |
| --- | --- | --- |
| Screen, input, audio, virtual displays | [scrcpy](https://github.com/Genymobile/scrcpy) | Fork the server with our patches. Phase 1 drives the stock client binary; phase 3 swaps in a native Mac window. |
| Phone to Mac files via the Android share sheet | [NearDrop](https://github.com/grishka/NearDrop) | Ship it as is in phase 1, then merge it into our app. Its share extension also sends Mac files to the phone. |
| Cable-free reconnection | [Shizuku](https://github.com/RikkaApps/Shizuku) ideas, adb mDNS | Phase 2: re-enable adb over Wi-Fi after reboot from the phone. |
| Notifications, SMS codes | Existing `android/` notification listener code | Phase 4. |
| Phone camera as Mac webcam | scrcpy `--video-source=camera` + a CoreMediaIO extension (existing `MirrorWebcamExtension`) | Phase 4. |

## Phases

### Phase 1: core features over USB and Wi-Fi

Goal: a menu bar app you use daily.

- Build scrcpy-server from source with the desk-mode patch. Stop the keep-alive thread when the display is released. Pin client and server to the same version.
- Mac menu bar app (reuse the existing SwiftUI shell): finds the phone over USB or saved Wi-Fi IP, switches the phone to `adb tcpip`, and launches desk mode or panel-off mirror.
- Clipboard: one background scrcpy session with no video. Our Mac code watches `NSPasteboard.changeCount` and sends scrcpy's `SET_CLIPBOARD` message. Fix phone-to-Mac, with server-side polling as the fallback.
- Files: drag onto the mirror window to push into `Download/` (scrcpy already does this). Bundle NearDrop for Quick Share from the phone.
- Tests: each item above gets a manual check on the Pixel plus scripted checks like the ones in this file.

### Phase 2: usable every day

Reordered on 2026-11-19 after the Phase 1 hand test. Wi-Fi already works, so the old Phase 2 (cable-free after reboot) moves to Phase 3. Every item below comes from that test.

| Test note | Cause | Fix |
| --- | --- | --- |
| Desk mode: Back, Home and Recents vanish when the phone locks | Android hides the desktop taskbar while the keyguard shows | Native window with its own Back, Home, Recents bar. Keys go to the virtual display, which stays unlocked. |
| Desk mode: swiping the status bar opens it on the phone | The notification shade only exists on the phone's own screen | No shade button in desk mode. Phone notifications on the Mac stay in Phase 4. |
| Mirror stutters | SDL window, H.264 at 8 Mbit/s | Native window: H.265, 16 Mbit/s, VideoToolbox into Metal |
| Trackpad scroll stops dead | scrcpy sends wheel events; Android does not fling wheel scrolls | Two-finger trackpad scroll becomes a one-finger touch drag, so Android flings it like a real swipe. A mouse wheel still sends wheel events. |
| Two power presses to use the phone after mirroring | Under investigation. A clean session end restores the panel (checked on the Pixel). | See HANDOFF.md |
| Dropped files show no progress | scrcpy pushes in the background with no feedback | Our own adb sync push with a progress bar in the window |
| NearDrop is a second menu bar icon | It ships as its own app | Build NearDrop's `NearbyShare` code into Mirror; transfers show in Mirror's menu and notifications |

### Phase 3: no cable, survives reboot; window polish

Started 2026-11-19 together with the fixes from the Phase 2 hand test (see HANDOFF.md).

| Item | State |
| --- | --- |
| Mac finds the phone through adb mDNS (`_adb-tls-connect._tcp`, `_adb._tcp`) when the saved address fails | done |
| Pinch to zoom | done, needs a hand test |
| One Mac window per phone app on its own virtual display | done |
| Resize the desk virtual display with the window | done, needs a hand test |
| Phase 3 hand test fixes: Mac audio, lock screen clock, desk Overview, resize taps, solo app bars, resumable transfers (see HANDOFF.md) | done, needs a hand test |
| Android companion app: one-time `pm grant ... WRITE_SECURE_SETTINGS`, then it turns on wireless debugging on approved networks after a reboot | not started |
| Quick Settings tile on the phone: "Use on Mac" | not started |

### Phase 4: extras

- Notifications and 2FA codes on the Mac.
- Phone camera and mic as Mac webcam.
- Per-app FLAG_SECURE workaround guide (LSPatch).

## What happens to the old code

Decision pending. Recommended: move `crates/`, the custom pairing protocol and `NearDropReceiver` to an `archive/` branch, keep the SwiftUI shell, `MirrorRenderer`, and the Android notification listener.
