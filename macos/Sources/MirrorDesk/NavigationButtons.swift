import AppKit

/// Android navigation as buttons in the window's title bar. Android hides its own taskbar
/// while the phone is locked, so desk mode depends on these.
///
/// Shortcuts follow scrcpy's (Cmd in place of scrcpy's Alt): Cmd+B, Cmd+H, Cmd+S, Cmd+N.
/// Cmd+K opens the Apps menu.
enum NavigationButtons {
    enum Button: CaseIterable {
        case back, home, recents, notifications, apps

        var symbol: String {
            switch self {
            case .back: "arrowtriangle.backward"
            case .home: "circle"
            case .recents: "square"
            case .notifications: "bell"
            case .apps: "square.grid.3x3"
            }
        }

        var label: String {
            switch self {
            case .back: "Back"
            case .home: "Home"
            case .recents: "Recent apps"
            case .notifications: "Notifications"
            case .apps: "Open an app"
            }
        }

        var key: String {
            switch self {
            case .back: "b"
            case .home: "h"
            case .recents: "s"
            case .notifications: "n"
            case .apps: "k"
            }
        }

        /// Desk mode: the phone is locked, so Recents and the notification shade do nothing
        /// there. Apps opens the Mac-drawn launcher; its dock stands in for Recents.
        static func forMode(desk: Bool) -> [Button] {
            desk ? [.back, .home, .apps] : [.back, .home, .recents, .notifications]
        }
    }

    @MainActor
    static func controller(buttons: [Button], action: @escaping (Button) -> Void) -> NSTitlebarAccessoryViewController {
        let views = buttons.map { button -> NSButton in
            let view = ClosureButton { _ in action(button) }
            view.image = NSImage(systemSymbolName: button.symbol, accessibilityDescription: button.label)
            view.bezelStyle = .texturedRounded
            view.isBordered = false
            view.keyEquivalent = button.key
            view.keyEquivalentModifierMask = .command
            view.toolTip = "\(button.label) (⌘\(button.key.uppercased()))"
            view.widthAnchor.constraint(equalToConstant: 28).isActive = true
            return view
        }
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 8)
        // Title bar accessories keep the frame they start with; a zero frame hides them.
        stack.frame = NSRect(x: 0, y: 0, width: CGFloat(views.count) * 30 + 8, height: 28)
        let controller = NSTitlebarAccessoryViewController()
        controller.view = stack
        controller.layoutAttribute = .trailing
        return controller
    }
}

private final class ClosureButton: NSButton {
    private let handler: (NSButton) -> Void

    init(handler: @escaping (NSButton) -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        target = self
        action = #selector(fire)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { handler(self) }
}
