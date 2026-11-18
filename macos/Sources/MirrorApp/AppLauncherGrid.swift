import SwiftUI

public struct InstalledAppItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let packageName: String
    public let systemImage: String

    public init(name: String, packageName: String, systemImage: String) {
        self.id = packageName
        self.name = name
        self.packageName = packageName
        self.systemImage = systemImage
    }
}

/// Launches selected Android apps directly inside the embedded Mac phone mirror viewport.
public struct AppLauncherGrid: View {
    @ObservedObject var agent: MirrorAppAgent

    private let apps: [InstalledAppItem] = [
        InstalledAppItem(name: "WhatsApp", packageName: "com.whatsapp", systemImage: "message.fill"),
        InstalledAppItem(name: "Messages", packageName: "com.google.android.apps.messaging", systemImage: "bubble.left.fill"),
        InstalledAppItem(name: "Photos", packageName: "com.google.android.apps.photos", systemImage: "photo.on.rectangle"),
        InstalledAppItem(name: "Chrome", packageName: "com.android.chrome", systemImage: "safari.fill"),
        InstalledAppItem(name: "Files", packageName: "com.google.android.apps.nbu.files", systemImage: "folder.fill"),
        InstalledAppItem(name: "Settings", packageName: "com.android.settings", systemImage: "gearshape.fill")
    ]

    public init(agent: MirrorAppAgent) {
        self.agent = agent
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: MirrorTokens.space3) {
            HStack {
                Text("Quick Launch inside Mirror")
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer()
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: MirrorTokens.space2), count: 3), spacing: MirrorTokens.space2) {
                ForEach(apps) { app in
                    Button {
                        agent.launchApp(packageName: app.packageName)
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: app.systemImage)
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(agent.isConnected ? MirrorTokens.accent : .secondary)
                            Text(app.name)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(MirrorTokens.raisedSurface, in: RoundedRectangle(cornerRadius: MirrorTokens.innerRadius, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(!agent.isConnected)
                }
            }
        }
        .padding(MirrorTokens.space3)
        .background(MirrorTokens.cardSurface, in: RoundedRectangle(cornerRadius: MirrorTokens.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: MirrorTokens.cardRadius, style: .continuous)
                .stroke(MirrorTokens.hairlineBorder, lineWidth: 1)
        )
    }
}
