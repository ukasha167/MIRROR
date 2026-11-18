import SwiftUI
import AppKit
import MirrorDesk

// The old dashboard (MirrorApp target, custom pairing protocol) is no longer launched.
// ROADMAP.md, "What happens to the old code", tracks whether it gets archived.
@main
struct MirrorMainApp: App {
    @StateObject private var desk = DeskController()

    init() {
        // Menu bar only: no Dock icon, no main window.
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra("Mirror", systemImage: "iphone.and.arrow.forward") {
            DeskMenu(desk: desk)
        }
    }
}

/// Phase 1 menu: scrcpy-based desk mode, panel-off mirror, clipboard sync, Quick Share.
struct DeskMenu: View {
    @ObservedObject var desk: DeskController

    var body: some View {
        Text(desk.phoneLabel)
        if desk.phone != nil && desk.status != "Ready" {
            Text(desk.status).font(.caption)
        }

        Divider()

        Button(desk.openWindows.contains(.desk) ? "Close Desk Mode" : "Open Desk Mode") {
            desk.toggle(.desk)
        }
        .disabled(desk.phone == nil)
        Button(desk.openWindows.contains(.panelOff) ? "Close Phone Screen" : "Mirror Phone Screen (Panel Off)") {
            desk.toggle(.panelOff)
        }
        .disabled(desk.phone == nil)

        Divider()

        Toggle("Sync Clipboard", isOn: $desk.clipboardEnabled)
        Button("Open Quick Share Receiver (NearDrop)") {
            QuickShareLauncher.open()
        }

        Divider()

        Button("Quit Mirror") {
            desk.shutdown()
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
