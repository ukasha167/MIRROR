import Foundation

/// A launchable app on the phone.
public struct PhoneApp: Equatable, Sendable {
    public var name: String
    public var package: String
    public var isSystem: Bool
}

/// App list and display commands for desk mode. Android ignores the Home and Recents keys
/// while the keyguard shows, even on an always-unlocked display, and the desktop launcher
/// hides its icons. So desk mode launches apps itself.
public enum PhoneApps {
    /// Parses scrcpy-server's `list_apps=true` output. App lines look like
    /// ` * Chrome                         com.android.chrome` (`*` system, `-` user app).
    public static func parse(_ output: String) -> [PhoneApp] {
        output.split(separator: "\n").compactMap { line in
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("* ") || text.hasPrefix("- ") else { return nil }
            let fields = text.dropFirst(2).split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2, let package = fields.last else { return nil }
            let name = fields.dropLast().joined(separator: " ")
            return PhoneApp(name: name, package: String(package), isSystem: text.hasPrefix("*"))
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Finds the virtual display id in the server log line
    /// `INFO: New display: 1600x1000/200 (id=27)`.
    public static func virtualDisplayID(inServerLog log: String) -> Int? {
        guard let range = log.range(of: #"New display: \S+ \(id=(\d+)\)"#, options: .regularExpression) else { return nil }
        let match = log[range]
        guard let open = match.range(of: "id=") else { return nil }
        return Int(match[open.upperBound...].dropLast())
    }

    /// Lists apps with the server jar the mirror session already pushed (about 1.5 s on a Pixel 7 Pro).
    public static func load(adb: String, serial: String, serverVersion: String = "4.1") async throws -> [PhoneApp] {
        let out = try await ProcessCommandRunner().run(adb, [
            "-s", serial, "shell", "CLASSPATH=/data/local/tmp/scrcpy-server.jar",
            "app_process", "/", "com.genymobile.scrcpy.Server", serverVersion, "list_apps=true",
        ])
        return parse(out.stdout)
    }

    /// Brings the desktop home screen to the front of `displayId`.
    public static func homeArguments(serial: String, displayId: Int) -> [String] {
        ["-s", serial, "shell", "am", "start", "--display", "\(displayId)",
         "-a", "android.intent.action.MAIN", "-c", "android.intent.category.SECONDARY_HOME"]
    }
}

/// Apps opened from the Mac, newest first, so the Apps menu can list them at the top.
public struct RecentApps {
    static let key = "MirrorDesk.recentApps"
    public static let limit = 8
    let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var packages: [String] { defaults.stringArray(forKey: Self.key) ?? [] }

    public func record(_ package: String) {
        let list = [package] + packages.filter { $0 != package }
        defaults.set(Array(list.prefix(Self.limit)), forKey: Self.key)
    }
}
