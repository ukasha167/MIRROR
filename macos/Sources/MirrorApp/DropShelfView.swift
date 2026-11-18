import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Drag-and-drop and click-to-browse transfer drop shelf pushing files to `/sdcard/Download/`.
public struct DropShelfView: View {
    @ObservedObject var agent: MirrorAppAgent
    @State private var isDropTargeted = false

    public init(agent: MirrorAppAgent) {
        self.agent = agent
    }

    public var body: some View {
        VStack(spacing: MirrorTokens.space2) {
            HStack(spacing: MirrorTokens.space3) {
                Image(systemName: isDropTargeted ? "arrow.down.doc.fill" : "arrow.up.doc")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(isDropTargeted ? MirrorTokens.accent : .secondary)
                    .frame(width: 34, height: 34)
                    .background(MirrorTokens.raisedSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(isDropTargeted ? "Release to send to phone" : "Send Files to Phone")
                        .font(.system(size: 12.5, weight: .semibold))
                    Text(agent.fileTransferMessage ?? "Drag files here or choose from Finder")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Button("Choose File...") {
                    pickFileAndPush()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!agent.isConnected)
            }
        }
        .padding(MirrorTokens.space3)
        .background(
            isDropTargeted ? MirrorTokens.accent.opacity(0.08) : MirrorTokens.cardSurface,
            in: RoundedRectangle(cornerRadius: MirrorTokens.cardRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MirrorTokens.cardRadius, style: .continuous)
                .strokeBorder(
                    isDropTargeted ? MirrorTokens.accent : MirrorTokens.hairlineBorder,
                    style: StrokeStyle(lineWidth: isDropTargeted ? 1.5 : 1, dash: isDropTargeted ? [5, 3] : [])
                )
        )
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            guard agent.isConnected else { return false }
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in _ = await agent.pushFile(url: url) }
                }
            }
            return true
        }
    }

    private func pickFileAndPush() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            for url in panel.urls {
                Task { _ = await agent.pushFile(url: url) }
            }
        }
    }
}
