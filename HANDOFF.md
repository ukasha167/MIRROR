# Handoff

Last updated 2026-11-18. Read `ROADMAP.md` first; this file says where Phase 1 stands.

## Phase 1 status

Nothing is committed yet. All Phase 1 work sits in the working tree on `main`.

| Roadmap item | State | Checked how |
| --- | --- | --- |
| scrcpy-server from source with desk-mode patch | done | `scripts/build-scrcpy-server.sh` builds `build/scrcpy-server-v4.1` in 5 s |
| Stop keep-alive thread when display is released | done | patch 0001; live run on Pixel: virtual display stayed ON 16 s with keyguard showing |
| Pin client and server versions | done | script reads `scrcpy --version`; app looks for `scrcpy-server-v<client version>` only |
| Menu bar app finds phone over USB or saved Wi-Fi, runs `adb tcpip` | done | `mirror-desk locate` on Pixel: USB found, `192.168.18.230:5555` connected |
| Launch desk mode or panel-off mirror from the menu | done, not clicked by hand | args covered by unit tests; desk mode run from the shell with the same args |
| Clipboard: no-video scrcpy session, `NSPasteboard.changeCount` watch, `SET_CLIPBOARD` | done | `mirror-desk clipboard-roundtrip` passes both directions on Pixel |
| Phone-to-Mac clipboard fix | done | patch 0002 adds a 1 s server-side poll of `getPrimaryClip()` |
| Files: drag onto mirror window | upstream scrcpy, untouched | not re-tested |
| NearDrop for Quick Share | built, not tested | `scripts/build-neardrop.sh` makes ad-hoc signed `build/NearDrop/NearDrop.app` (2 min) |

`swift test` in `macos/`: 44 tests pass (21 new in `MirrorDeskTests.swift`).

## What changed

- `patches/scrcpy-v4.1/0001-desk-mode-virtual-display.patch`: reworked. Keep-alive thread is a field, stopped in `release()`, and logs then exits if `userActivity` throws.
- `patches/scrcpy-v4.1/0002-clipboard-poll-fallback.patch`: new. Listener and poll share `lastSyncedClipboard`, so the same text is never sent twice; text the Mac sets is recorded there too, so it does not echo back.
- `macos/Sources/MirrorDesk/`: new target. `AdbClient`, `PhoneLocator`, `ScrcpyLaunch` (mode args, server lookup, window process), `ScrcpyControlWire` (SET_CLIPBOARD encoder, device message parser), `ScrcpyControlSession` (control-only server over adb forward), `ClipboardSync` (bridge plus echo guard), `DeskController` (menu state), `QuickShareLauncher`.
- `macos/Sources/MirrorDeskCLI/`: `mirror-desk locate | clipboard-roundtrip` for scripted phone checks.
- `macos/Sources/MirrorAppLauncher/MirrorMain.swift`: the app is now menu bar only (`.accessory`) with the Phase 1 menu. The old dashboard window and `MirrorAppAgent` are no longer launched; their code is untouched in the `MirrorApp` target.
- `Makefile`: `scrcpy-server`, `neardrop`, `phone-check` targets.

## Things learned

- Homebrew scrcpy is 4.1; Homebrew already offers 5.0.1, and `third_party/scrcpy` is 5.0.1. `brew upgrade scrcpy` will make the app report "No patched server for scrcpy 5.0.1" until someone adds `patches/scrcpy-v5.0.1/`. Pin with `brew pin scrcpy` or rebase the two patches.
- A control-only server needs `send_device_meta=false`. Otherwise it sends a 64-byte device name after the dummy byte, our parser reads it as message type 0x50, closes the socket, and the server exits with status 0 and no error.
- `adb shell cmd clipboard` does not exist on Android 17. To test the phone clipboard, run two control sessions: one sets, the other must see the change (that is what `clipboard-roundtrip` does).
- The menu polls `adb devices` every 5 s. That is one short process per tick; switch to `adb track-devices` if idle CPU matters.

## Manual checks still to do on the Pixel

1. `swift run MirrorApp` in `macos/`, then from the menu: Open Desk Mode, lock the phone, use an app for a minute.
2. Mirror Phone Screen (Panel Off) with the phone unlocked; confirm the panel goes dark and input works.
3. Copy text in a phone app (a real copy, not `SET_CLIPBOARD`) and paste on the Mac; then the reverse.
4. Unplug USB while the app runs; the menu should switch to "(Wi-Fi)" within 5 s and clipboard sync should restart.
5. Drag a file onto a mirror window; it should land in `Download/`.
6. Open NearDrop from the menu, share a file from the phone's Quick Share sheet.

The phone was left locked after the desk-mode test.

## Next

Finish the manual checks above, commit Phase 1, then start Phase 2 (companion app with `WRITE_SECURE_SETTINGS`, mDNS reconnect).
