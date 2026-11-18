import Foundation

#if canImport(AppKit)
import AppKit
#endif

/// Configuration for an independent Android Virtual Display window.
public struct VirtualDisplayConfig: Sendable, Equatable {
    public let appPackage: String
    public var width: Int
    public var height: Int
    public var dpi: Int
    public let displayId: Int

    public init(
        appPackage: String,
        width: Int = 1080,
        height: Int = 2340,
        dpi: Int = 420,
        displayId: Int = 1
    ) {
        self.appPackage = appPackage
        self.width = width
        self.height = height
        self.dpi = dpi
        self.displayId = displayId
    }

    /// Formats command-line arguments for scrcpy virtual display launcher.
    public var scrcpyArguments: [String] {
        [
            "--new-display=\(width)x\(height)/\(dpi)",
            "--start-app=\(appPackage)",
            "--no-vd-destroy-content",
            "--no-vd-system-decorations",
            "--display-ime-policy=local",
            "--flex-display"
        ]
    }
}

/// Controller managing independent per-app virtual display streaming sessions.
public final class VirtualDisplayController: @unchecked Sendable {
    private var activeDisplays: [Int: VirtualDisplayConfig] = [:]
    private let lock = NSLock()

    public init() {}

    /// Registers a new active virtual display session.
    public func startDisplay(for appPackage: String, displayId: Int) -> VirtualDisplayConfig {
        lock.lock()
        defer { lock.unlock() }
        let config = VirtualDisplayConfig(appPackage: appPackage, displayId: displayId)
        activeDisplays[displayId] = config
        return config
    }

    /// Handles dynamic window resize events (`--flex-display`).
    public func handleWindowResize(displayId: Int, newWidth: Int, newHeight: Int) -> VirtualDisplayConfig? {
        lock.lock()
        defer { lock.unlock() }
        guard var config = activeDisplays[displayId] else { return nil }
        config.width = max(320, newWidth)
        config.height = max(480, newHeight)
        activeDisplays[displayId] = config
        return config
    }

    /// Terminates a virtual display session and returns the final config for teardown.
    public func stopDisplay(displayId: Int) -> VirtualDisplayConfig? {
        lock.lock()
        defer { lock.unlock() }
        return activeDisplays.removeValue(forKey: displayId)
    }

    /// Returns all running virtual displays.
    public func allActiveDisplays() -> [VirtualDisplayConfig] {
        lock.lock()
        defer { lock.unlock() }
        return Array(activeDisplays.values)
    }
}
