# Handoff

Last updated 2026-11-19. Read `ROADMAP.md` first. Phases 1 and 2 are committed; Phase 3 is under way.

## Phase 2 hand test results and fixes

| Hand test note | Cause | Fix | Checked how |
| --- | --- | --- | --- |
| Desk mode: dock and home screen icons gone while locked | Android hides the desktop launcher's icons and taskbar behind the keyguard | Mac-drawn launcher (search, 132 apps with icons) over the video, and a dock of apps opened from the Mac under it. Home shows the launcher. | Screenshot with `isKeyguardShowing=true`: all icons drawn |
| Desk mode: Apps button did nothing | scrcpy-server deletes its jar at start, so the app list ran against a missing file and returned nothing | Listing pushes its own copy (`mirror-apps.jar`, `cleanup=false`). Patch 0003 adds `app_icons_dir`, which writes each app's icon as a PNG. | Same screenshot |
| Transfer slows the mirror | adb carries the push and the video over one connection; Wi-Fi push measured 6 MB/s on this network | Push capped at 3 MB/s over Wi-Fi while a mirror is open; Wi-Fi video 8 Mbit/s instead of 16 | `Pacer` unit test only. Needs a hand test. |
| Plugging in the cable mid-transfer should use it | The push kept its Wi-Fi serial | When the phone moves from Wi-Fi to USB, the file in flight starts again over USB. A failed file is retried once on whatever transport is current. Open windows also move to USB. | Unit tests only |
| Window got wider with the transfer bar and stayed wide | The bar's text pushed the window's minimum width | Bar removed. Progress is in the menu bar title ("42%") and the menu, with Stop Sending. | Builds; needs a look |
| Power press ends the mirror | We closed the window on purpose in Phase 2 | First press wakes the phone, turns its panel on, mirror keeps going. Later presses are left alone. | Sleep then wake with `input keyevent`: window stayed open. A real press needs a hand test. |
| Unplugging the cable ends the mirror | The stream died with the USB transport | Window shows "Reconnecting" and starts a new session over USB or Wi-Fi as soon as the phone is found. Desk mode reopens the last app. | `adb reconnect` mid-session: window stayed open, new session started |

Desk mode now sizes the virtual display from the window: 1.5 phone pixels per Mac point at 240 dpi, so one dp is one Mac point. A 1008 x 630 point window gave a 1512 x 944 display.

`swift test` in `macos/`: 76 tests pass.

## New tools

- `mirror-window app <package>`: one app in its own window.
- `make scrcpy-server` now applies patch 0003 (app icons). The built server is in `build/`.

## Hand checks to do

1. Desk mode with the phone locked: launcher, search (type then Return), dock, Home, right-click "Open in New Window".
2. Drag the desk window's corner. The phone apps should re-layout to the new size about 150 ms after you stop.
3. Pinch in Google Maps or Photos.
4. Panel-off mirror, press the power key once: phone lights up, Mac window keeps mirroring.
5. Start a 1 GB drop over Wi-Fi with a mirror open: is the video smooth? Plug the cable in mid-way: the menu should switch to "over USB" and finish fast.
6. Pull the cable during a USB mirror: "Reconnecting", then video over Wi-Fi.

## Things learned

- scrcpy-server unlinks its own jar at start unless `cleanup=false`.
- `flex_display=true` plus `RESIZE_DISPLAY` (type 21, two big-endian u16) resizes a virtual display live.
- `screencapture -l <window id>` captures a window on another Space; the window id comes from `CGWindowListCopyWindowInfo`.
- Scripted window resizing needs Accessibility permission, which this terminal lacks.

## Next

Hand checks above, then the Android companion app and Quick Settings tile (ROADMAP Phase 3).
