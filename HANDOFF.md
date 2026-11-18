# Handoff

Last updated 2026-11-19. Read `ROADMAP.md` first. Phases 1 and 2 are committed; Phase 3 is under way. All Phase 3 items are built; hand checks remain.

## Phase 3 hand test results and fixes (2026-11-19)

| Hand test note | Cause | Fix | Checked how |
| --- | --- | --- | --- |
| Desk: sound plays on the phone | Sessions ran with `audio=false` | Desk and panel-off windows ask for raw PCM (`audio_codec=raw`, 1.5 Mbit/s) and play it with `AVAudioEngine`. Capture mutes the phone's speaker. 60 ms start cushion, 120 ms cap. Solo app windows take no audio. | YouTube on the desk display: the Mac read frames at the rate the phone sent them. Not listened to. |
| Desk: lock screen clock covers the desk and takes every touch | SystemUI shows `KeyguardPresentation` on every public presentation display while the keyguard shows. scrcpy sets `VIRTUAL_DISPLAY_FLAG_PRESENTATION`. | Patch 0004 drops the flag | Display now lacks `FLAG_PRESENTATION`. The unlock-then-lock case needs a hand test (PIN). |
| Desk: Overview button does nothing | Android has no Recents screen on a virtual display; `KEYCODE_APP_SWITCH` on it does nothing | Recents button (Cmd+S) opens a Mac-drawn Overview: apps on the desk display from `dumpsys activity activities`, click to switch, x closes with `am stack remove` | Screenshot with Clock and Calculator open |
| Desk: after a resize, taps land off | `MirrorMetalNSView.layout()` set its own backing layer's frame to `bounds`, which moved the video one dock height (54 pt) down | Line removed; AppKit owns that frame | `pointer_location` on, injected tap at 25%/25% after a resize: the crosshair now sits where the Mac maps it |
| Open in New Window: app not usable | Android's status bar and taskbar sat over the app's bottom tabs | Solo app displays use `vd_system_decorations=false`. All desk displays use `display_ime_policy=local`, so the keyboard opens there. | Clock in its own window: tabs visible |
| Transfer starts again when the transport changes | adb sync cannot write at an offset, and adbd deletes an unfinished file | `AdbResumablePush`: 32 MiB segments over sync, each spliced into a hidden partial file with a positional `dd`, renamed when complete. A switch repeats at most one segment. | Stopped a Wi-Fi push at 45%, resumed over USB at 42%: md5 matches. USB speed 25 MB/s (plain sync 33 MB/s; `exec:` into dd 12 MB/s). |
| Whole file name in the menu; menu bar title changes width | Full name in the menu line; percentage text of 1 to 3 digits | Names cut to 32 characters in the middle. Badge padded with figure spaces and drawn with tabular digits. | Unit tests. Needs a look. |
| Stop Sending hangs | The push thread was blocked in a socket write on a slow link, and the menu waited for it | Stop reports at once, shuts the socket down (`shutdown(2)`), and deletes the partial file | Unit test. Needs a hand test. |

`swift test` in `macos/`: 89 tests pass. Rebuild the server (`make scrcpy-server`) and restart the menu bar app to pick up all of this.

## Companion app (2026-11-19)

`android/companion` (package `dev.mirror.companion`) is a new, small app for the adb design. The old `android/app` is untouched; it belongs to the custom-protocol design that ROADMAP plans to archive.

- Android turns `adb_wifi_enabled` (Wireless debugging) off at every boot and every Wi-Fi drop. The app sets it back to 1 when the phone joins an approved Wi-Fi network.
- It wakes through `registerNetworkCallback(request, PendingIntent)` and `BOOT_COMPLETED`. Nothing runs between those wakes: no service, no wakelock.
- Approved networks are matched by Wi-Fi name. Android's own trusted list is keyed by BSSID, so a different access point of the same mesh shows Android's "Allow on this network?" dialog once.
- Android hides the Wi-Fi name from apps without location, so the Mac also grants fine and background location.
- The Mac runs the grant and approve step (`CompanionSetup`) on the first USB locate of each phone boot, before `adb tcpip`. `make companion` builds, installs and sets it up.
- The "Use on Mac" tile toggles Wireless debugging on the current network. It does not approve the network.

Checked on the Pixel: `mirror-desk companion <apk>` installed the app, granted the three permissions and approved `HUAWEI-5G-9fDV`. `adb_wifi_enabled` went to 1, adb's mDNS browser saw `_adb-tls-connect._tcp`, and `adb connect` to the TLS port succeeded with the key trusted over USB (no pairing code). Not checked: a real reboot.

## New tools

- `mirror-window app <package>`: one app in its own window.
- `mirror-desk push <file>` uses the resumable push. `MIRROR_SERIAL` picks a transport, `MIRROR_STOP_AT=<percent>` stops partway.
- `make scrcpy-server` now applies patch 0003 (app icons). The built server is in `build/`.
- `mirror-desk companion [apk]`: installs (with an apk) and sets up the companion app over USB. `make companion` builds the apk first.

## Hand checks to do

1. Desk mode: play a video. Sound on the Mac, phone speaker quiet. Is the lag acceptable over Wi-Fi?
2. Desk mode open, unlock the phone, use it, lock it. The desk should stay usable (no clock).
3. Recents button (or Cmd+S) in desk mode with two apps open: switch, then close one.
4. Drag the desk window's corner, then tap small targets near the bottom.
5. Right-click an app, Open in New Window: whole app visible, typing works.
6. Send a 1 GB file over Wi-Fi, plug the cable in at 30%: the menu should continue from about 30% over USB. Pull the cable: it should continue over Wi-Fi.
7. Stop Sending mid-file: the menu says "Stopped" at once.
8. Reboot the phone, unlock it, leave the cable out. Within a minute of joining home Wi-Fi, open Mirror's menu on the Mac: desk mode should start over Wi-Fi.
9. Add the "Use on Mac" tile. Tap it off and on: the subtitle follows, and Developer options shows Wireless debugging changing.
10. Join a network that is not approved (phone hotspot from another phone): no Android dialog should appear by itself.

## Things learned

- scrcpy-server unlinks its own jar at start unless `cleanup=false`.
- `flex_display=true` plus `RESIZE_DISPLAY` (type 21, two big-endian u16) resizes a virtual display live.
- `screencapture -l <window id>` captures a window on another Space; the window id comes from `CGWindowListCopyWindowInfo`.
- Scripted window resizing needs Accessibility permission, which this terminal lacks. A test can resize its own window instead.
- `settings put system pointer_location 1` draws touches on the virtual display too, which shows where an injected tap lands.
- An NSView must not set its own backing layer's frame.
- Toybox `dd` supports `seek=`, `conv=notrunc` and `oflag=seek_bytes`.
- adbd's TLS port (Wireless debugging) accepts any key in `adb_keys`, including keys allowed over USB. `adb pair` is only needed for a Mac that never had the cable.
- `dumpsys adb` shows the Wireless debugging state, the TLS port and whether the current network is trusted.
- Android delivers no clicks to a Quick Settings tile in `STATE_UNAVAILABLE`.

## Next

Hand checks above. Then Phase 4, and the decision on archiving the old `android/app`, `crates/` and pairing code.
