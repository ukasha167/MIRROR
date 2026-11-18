import Foundation

/// A launchable app on the phone.
public struct PhoneApp: Equatable, Sendable {
    public var name: String
    public var package: String
    public var isSystem: Bool

    public init(name: String, package: String, isSystem: Bool) {
        self.name = name
        self.package = package
        self.isSystem = isSystem
    }
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

    /// The list command's own copy of the server. The mirror session's server deletes its jar
    /// when it starts, so listing with that path failed and left the Apps menu empty (Phase 2
    /// hand test). `cleanup=false` stops this run from deleting its copy too.
    public static let listJar = "/data/local/tmp/mirror-apps.jar"
    public static let remoteIconDir = "/data/local/tmp/mirror-icons"

    /// Where pulled icons live on the Mac: `<cache>/<package>.png`.
    public static let iconCache: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Mirror/mirror-icons", isDirectory: true)

    public static func listArguments(serial: String, serverVersion: String = "4.1") -> [String] {
        ["-s", serial, "shell", "CLASSPATH=\(listJar)", "app_process", "/", "com.genymobile.scrcpy.Server",
         serverVersion, "list_apps=true", "cleanup=false", "app_icons_dir=\(remoteIconDir)"]
    }

    /// Lists apps and pulls their icons (needs the app-icons server patch). About 3 s and 1 MB
    /// for 130 apps on a Pixel 7 Pro. Icons that fail to pull leave the app without one.
    public static func load(adb: String, serial: String, serverPath: String) async throws -> [PhoneApp] {
        let run = ProcessCommandRunner()
        _ = try await run.run(adb, ["-s", serial, "push", serverPath, listJar])
        let out = try await run.run(adb, listArguments(serial: serial))
        let parent = iconCache.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: iconCache)
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        _ = try? await run.run(adb, ["-s", serial, "pull", remoteIconDir, parent.path])
        _ = try? await run.run(adb, ["-s", serial, "shell", "rm", "-rf", remoteIconDir])
        return parse(out.stdout)
    }

    /// The app's icon pulled by `load`, if any.
    public static func icon(for package: String) -> URL? {
        let url = iconCache.appendingPathComponent("\(package).png")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
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
