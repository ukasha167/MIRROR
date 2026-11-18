import Foundation

/// How the phone appears on the Mac.
public enum MirrorMode: Equatable, Sendable {
    /// A second Android screen that stays awake while the phone is locked (needs the desk-mode
    /// server patch). Apps open in tablet layout.
    case desk(width: Int, height: Int, dpi: Int)
    /// The phone's own screen, with the phone's panel turned off. The phone must stay unlocked.
    case panelOff

    public static let defaultDesk = MirrorMode.desk(width: 1600, height: 1000, dpi: 200)
}

/// Our patched scrcpy-server and the version it was built for.
public struct ScrcpyServer: Equatable, Sendable {
    public var path: String
    public var version: String

    /// Looks for `scrcpy-server-v<version>` where the build script and app bundle put it.
    /// The version must equal the client's (`scrcpy --version`), or the client rejects the server.
    public static func locate(
        clientVersion: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleResources: String? = Bundle.main.resourcePath,
        repoRoot: String = ScrcpyServer.repoRoot
    ) -> ScrcpyServer? {
        let name = "scrcpy-server-v\(clientVersion)"
        var candidates: [String] = []
        if let override = environment["MIRROR_SCRCPY_SERVER"] { candidates.append(override) }
        if let res = bundleResources { candidates.append("\(res)/\(name)") }
        candidates.append("\(NSHomeDirectory())/Library/Application Support/Mirror/\(name)")
        candidates.append("\(repoRoot)/build/\(name)")
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            return ScrcpyServer(path: path, version: clientVersion)
        }
        return nil
    }

    /// Repository root, found from this source file's location. Lets `swift run` use
    /// `build/` without installing anything.
    public static let repoRoot: String = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() } // MirrorDesk, Sources, macos
        return url.path
    }()

    /// Reads the version from `scrcpy --version` ("scrcpy 4.1 <https://...>").
    public static func parseClientVersion(_ output: String) -> String? {
        let fields = output.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 2, fields[0] == "scrcpy" else { return nil }
        return String(fields[1])
    }
}

/// Builds the scrcpy client command line for a mirror window.
public struct ScrcpyLaunchConfig: Equatable, Sendable {
    public var serial: String
    public var mode: MirrorMode
    public var server: ScrcpyServer
    public var windowTitle: String

    public init(serial: String, mode: MirrorMode, server: ScrcpyServer, windowTitle: String) {
        self.serial = serial
        self.mode = mode
        self.server = server
        self.windowTitle = windowTitle
    }

    /// Phone screen timeout while a panel-off session runs, in seconds. scrcpy restores the
    /// old value on exit. Long, so the phone does not lock under the user mid-session.
    public static let panelOffScreenTimeout = 3600

    public var arguments: [String] {
        var args = ["--serial=\(serial)", "--window-title=\(windowTitle)"]
        // The clipboard bridge owns phone-to-Mac sync. Two writers would race on NSPasteboard.
        args.append("--no-clipboard-autosync")
        switch mode {
        case .desk(let width, let height, let dpi):
            args.append("--new-display=\(width)x\(height)/\(dpi)")
            // Keep apps alive on the phone after the window closes; the user can reopen them.
            args.append("--no-vd-destroy-content")
        case .panelOff:
            args.append("--turn-screen-off")
            args.append("--stay-awake")
            args.append("--screen-off-timeout=\(Self.panelOffScreenTimeout)")
        }
        return args
    }

    /// scrcpy reads the server jar location from this variable.
    public var environment: [String: String] {
        ["SCRCPY_SERVER_PATH": server.path]
    }
}

/// One running scrcpy client window.
public final class ScrcpyWindowProcess: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var output = Data()

    public var onExit: (@Sendable (_ exitCode: Int32, _ lastOutput: String) -> Void)?

    public init(scrcpyPath: String, config: ScrcpyLaunchConfig) {
        process.executableURL = URL(fileURLWithPath: scrcpyPath)
        process.arguments = config.arguments
        var env = ProcessInfo.processInfo.environment
        env.merge(config.environment) { _, new in new }
        // scrcpy runs adb itself; make sure it finds the same one we use.
        if let adb = try? ToolLocator.find("adb") { env["ADB"] = adb }
        process.environment = env
    }

    public func start() throws {
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self, !chunk.isEmpty else { return }
            self.lock.lock()
            self.output.append(chunk)
            if self.output.count > 16_384 { self.output = self.output.suffix(8_192) }
            self.lock.unlock()
        }
        process.terminationHandler = { [weak self] proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            guard let self else { return }
            self.lock.lock()
            let tail = String(decoding: self.output.suffix(2_000), as: UTF8.self)
            self.lock.unlock()
            self.onExit?(proc.terminationStatus, tail)
        }
        try process.run()
    }

    public var isRunning: Bool { process.isRunning }

    public func stop() {
        if process.isRunning { process.terminate() }
    }
}
