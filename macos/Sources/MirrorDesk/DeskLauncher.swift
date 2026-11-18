import AppKit
import SwiftUI

/// Desk mode's own home screen and dock. Android hides the desktop launcher's icons and its
/// taskbar while the phone is locked (Phase 2 hand test), so the Mac draws them from the app
/// list and icons that `PhoneApps.load` pulls.
@MainActor
final class DeskAppsModel: ObservableObject {
    @Published var apps: [PhoneApp]?
    @Published var recent: [String]
    @Published var launcherShown = true
    @Published var query = ""
    var open: (PhoneApp) -> Void = { _ in }
    var openWindow: (PhoneApp) -> Void = { _ in }
    private var icons: [String: NSImage] = [:]
    private let recentStore = RecentApps()

    init() { recent = recentStore.packages }

    var filtered: [PhoneApp] {
        guard let apps else { return [] }
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    /// Dock apps: the ones opened from the Mac, newest first.
    var dockApps: [PhoneApp] {
        let byPackage = Dictionary((apps ?? []).map { ($0.package, $0) }, uniquingKeysWith: { a, _ in a })
        return recent.compactMap { byPackage[$0] }
    }

    func launch(_ app: PhoneApp) {
        recentStore.record(app.package)
        recent = recentStore.packages
        query = ""
        launcherShown = false
        open(app)
    }

    func icon(_ app: PhoneApp) -> NSImage? {
        if let cached = icons[app.package] { return cached }
        guard let url = PhoneApps.icon(for: app.package), let image = NSImage(contentsOf: url) else { return nil }
        icons[app.package] = image
        return image
    }

    /// Icons are re-pulled with each app list; drop the old images.
    func setApps(_ list: [PhoneApp]) {
        icons.removeAll()
        apps = list
    }
}

struct AppIcon: View {
    let image: NSImage?
    let name: String
    let size: CGFloat

    var body: some View {
        if let image {
            Image(nsImage: image).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            // No icon pulled (older server build or a failed pull): first letter on a tile.
            RoundedRectangle(cornerRadius: size * 0.28)
                .fill(Color.gray.opacity(0.45))
                .frame(width: size, height: size)
                .overlay(Text(name.prefix(1).uppercased()).font(.system(size: size * 0.45, weight: .semibold)))
        }
    }
}

/// Full-window grid of every app with a search field. Shown at session start and on Home.
struct DeskLauncherView: View {
    @ObservedObject var model: DeskAppsModel
    @FocusState private var searchFocused: Bool

    private let columns = [GridItem(.adaptive(minimum: 92, maximum: 120), spacing: 12)]

    var body: some View {
        VStack(spacing: 14) {
            TextField("Search apps", text: $model.query)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
                .focused($searchFocused)
                .onSubmit { if let first = model.filtered.first { model.launch(first) } }
                .onExitCommand { model.launcherShown = false }
            if model.apps == nil {
                Spacer()
                ProgressView("Loading apps from the phone")
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(model.filtered, id: \.package) { app in
                            Button { model.launch(app) } label: {
                                VStack(spacing: 6) {
                                    AppIcon(image: model.icon(app), name: app.name, size: 52)
                                    Text(app.name).font(.system(size: 11)).lineLimit(1).truncationMode(.tail)
                                }
                                .frame(width: 92)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(app.package)
                            .contextMenu {
                                Button("Open in New Window") { model.openWindow(app) }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
        }
        .padding(.top, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .environment(\.colorScheme, .dark)
        .onAppear { searchFocused = true }
    }
}

/// Strip under the desk video: an all-apps button, then the apps opened from the Mac. Clicking
/// one brings its window to the front, which also stands in for Android's Recents screen.
struct DeskDockView: View {
    @ObservedObject var model: DeskAppsModel
    static let height: CGFloat = 54

    var body: some View {
        HStack(spacing: 10) {
            Button { model.launcherShown.toggle() } label: {
                Image(systemName: "square.grid.3x3.fill").font(.system(size: 18)).frame(width: 38, height: 38)
            }
            .buttonStyle(.plain)
            .help("All apps (⌘K)")
            Divider().frame(height: 30)
            ForEach(model.dockApps, id: \.package) { app in
                Button { model.launch(app) } label: { AppIcon(image: model.icon(app), name: app.name, size: 36) }
                    .buttonStyle(.plain)
                    .help(app.name)
                    .contextMenu {
                        Button("Open in New Window") { model.openWindow(app) }
                    }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .environment(\.colorScheme, .dark)
    }
}
