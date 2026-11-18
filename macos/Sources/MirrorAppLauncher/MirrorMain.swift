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
        MenuBarExtra {
            DeskMenu(desk: desk)
        } label: {
            // While a file goes to the phone, the menu bar shows how far it has got.
            if let badge = desk.transferBadge {
                Label(badge, systemImage: "arrow.up.circle").labelStyle(.titleAndIcon)
            } else {
                Image(systemName: "iphone.and.arrow.forward")
            }
        }
    }
}

/// Menu: native desk mode and panel-off mirror windows, clipboard sync, Quick Share receiver.
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

        if let transfer = desk.transferLabel {
            Divider()
            Text(transfer)
            if desk.isSending {
                Button("Stop Sending") { desk.stopSending() }
            }
        }

        Divider()

        Toggle("Sync Clipboard", isOn: $desk.clipboardEnabled)
        Text(desk.quickShareLabel)
        Button("Show Received Files") {
            NSWorkspace.shared.open(FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0])
        }

        Divider()

        Button("Quit Mirror") {
            desk.shutdown()
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
