# Handoff

Last updated 2026-11-19. Read `ROADMAP.md` first; this file says where Phase 2 stands. Phase 1 is committed.

## Phase 2 status

Every item comes from the Phase 1 hand test. "Checked" means a scripted or screenshot check on the Pixel 7 Pro over USB. Nothing below has had a full hand test yet.

| Test note | What changed | Checked how |
| --- | --- | --- |
| Mirror stutters | Native window (`MirrorWindowController`) replaces the scrcpy SDL window: H.265, 16 Mbit/s, 60 fps, VideoToolbox into Metal | `mirror-desk stream-check` decodes 886x1920 (panel-off) and 1600x1000 (desk); screenshots of both windows show live video |
| Trackpad scroll stops dead | `TrackpadScrollTranslator`: two-finger scroll becomes a one-finger touch drag that Android flings; momentum events dropped; mouse wheel unchanged | unit tests only. Fling feel needs a hand test. |
| Desk mode loses Back/Home/Recents when locked | Title bar buttons. Desk mode: Back (key), Home (starts `SECONDARY_HOME` on the virtual display), Apps menu (scrcpy START_APP). Panel-off: Back, Home, Recents, Notifications keys. Cmd+B/H/S/N/K. | With the keyguard showing: `input -d <vd> keyevent` Back closed Settings; Home and APP_SWITCH keys did nothing; the home intent and START_APP both worked (`stream-check desk com.google.android.calculator` PASS) |
| Status bar swipe opens the shade on the phone | Desk mode has no shade button; the shade only exists on the phone's own screen | n/a |
| Two power presses after mirroring | Cause found: a press mid-session takes the phone from Awake to Dozing with the panel still off. `PowerKeyWatcher` reads `getevent`, sends WAKEUP and ends the session | Simulated with `input keyevent SLEEP`: Dozing, panel off; WAKEUP: Awake, panel on. A real press needs a hand test. |
| Dropped files show no progress | `AdbSyncPush` speaks adb's sync protocol; `TransferBar` shows name, bytes and a stop button; files queue | `mirror-desk push` sent 100 MB in 3.1 s over USB; size matched on the phone. MediaStore indexed it with no scan. |
| NearDrop is a second menu bar icon | `macos/Vendor/NearbyShare` (NearDrop's code, Unlicense) builds into Mirror. Consent is an alert with the PIN; status is a menu line. NearDrop.app, its build script and `QuickShareLauncher` are gone. | Mirror's `_FC9F5ED42C8A._tcp` advert appears while it runs and goes when it quits. No transfer from the phone yet. |

`swift test` in `macos/`: 64 tests pass.

## New tools

- `swift run mirror-window [desk]`: opens one native window without the menu app. It has its own target because `NSApplication.run()` inside async top-level code blocks the main actor, and the window's tasks never start.
- `mirror-desk stream-check [desk [package]]`, `mirror-desk push <file>`. `make phone-check` runs the desk app-launch check too.

## Things learned

- Android drops HOME and APP_SWITCH while the keyguard shows, even for an `ALWAYS_UNLOCKED` virtual display. BACK still works.
- The desktop launcher on the virtual display shows only wallpaper while locked; its taskbar returns once the phone unlocks.
- The server prints `New display: WxH/dpi (id=N)`; that id is the only way we learn the virtual display.
- `screen_off_timeout` is in ms as a server option, seconds as a client flag.
- `timeout` is not installed on this Mac; scripts must not use it.

## Hand checks to do

1. `swift run MirrorApp`, Open Desk Mode, lock the phone. Use Back, Home and the Apps menu.
2. Two-finger scroll a long list in both windows. Does it fling like a phone swipe? Does the edge restart feel smooth?
3. Panel-off mirror, then press the phone's power button once. The phone should light up and the Mac window close.
4. Drop a 1 GB file on a window over Wi-Fi; watch the bar, then press stop mid-way.
5. Share a photo from the phone to the Mac with Quick Share; accept the alert.
6. Rotate the phone during panel-off mirroring; the window should reshape.

## Next

Hand checks above, then Phase 3 (cable-free after reboot).
