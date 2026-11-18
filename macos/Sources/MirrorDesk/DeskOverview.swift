import SwiftUI

/// Desk mode's Overview: one card per app open on the virtual display, front app first.
/// Click a card to bring that app forward; × closes it.
struct DeskOverviewView: View {
    @ObservedObject var model: DeskAppsModel

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 16)]

    var body: some View {
        VStack(spacing: 16) {
            Text("Open apps").font(.headline)
            if let tasks = model.overview {
                if tasks.isEmpty {
                    Spacer()
                    Text("No apps open on this desk").foregroundStyle(.secondary)
                    Spacer()
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(tasks, id: \.id) { task in card(task) }
                        }
                        .padding(.horizontal, 24)
                    }
                }
            }
        }
        .padding(.top, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .environment(\.colorScheme, .dark)
        .onExitCommand { model.overview = nil }
    }

    private func card(_ task: DeskTask) -> some View {
        let app = model.app(for: task.package)
        return Button { model.switchTo(task) } label: {
            VStack(spacing: 10) {
                AppIcon(image: model.icon(app), name: app.name, size: 64)
                Text(app.name).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 130)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            Button { model.close(task) } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 18)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(8)
            .help("Close \(app.name)")
        }
        .help(app.package)
    }
}
