import SwiftUI
import AppKit
import MirrorApp

@main
struct MirrorMainApp: App {
    @StateObject private var agent = MirrorAppAgent()

    var body: some Scene {
        Window("Mirror Continuity", id: "main-dashboard") {
            DashboardView(agent: agent)
        }
        .defaultSize(width: 980, height: 720)
        .windowResizability(.automatic)

        MenuBarExtra("Mirror Continuity", systemImage: "iphone.and.arrow.forward") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(agent.isConnected ? agent.deviceName : "Not Connected")
                        .font(.headline)
                    Spacer()
                    if agent.isConnected {
                        Text("\(agent.batteryPercentage)%")
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                }

                Divider()

                Button("Open Dashboard") {
                    NSApp.activate(ignoringOtherApps: true)
                    for window in NSApp.windows where window.title.contains("Mirror") {
                        window.makeKeyAndOrderFront(nil)
                    }
                }

                Divider()

                Button(agent.isMirroring ? "Stop Mirroring" : "Start Mirroring") {
                    Task { await agent.toggleScreenMirror() }
                }
                .disabled(!agent.isConnected)

                Button(agent.isWebcamActive ? "Stop Camera" : "Start Continuity Camera") {
                    agent.toggleWebcam()
                }
                .disabled(!agent.isConnected)

                Button(agent.isFinderVolumeMounted ? "Unmount Finder Volume" : "Mount in Finder Sidebar") {
                    agent.toggleFinderVolume()
                }
                .disabled(!agent.isConnected)

                Divider()

                Button("Quit Mirror") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(4)
        }
    }
}
