import AppKit
import MirrorDesk

// Opens one native mirror window without the menu bar app, for hand checks.
//
//   swift run mirror-window         panel-off mirror
//   swift run mirror-window desk    desk mode
//   swift run mirror-window app <package>   one app on its own display
//
// main is synchronous on purpose. NSApplication.run() inside async top-level code blocks the
// main actor, and the window's session tasks never start.

func fail(_ message: String) -> Never {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
}

/// Runs async setup to completion before the app loop starts.
func blocking<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) -> T {
    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: Result<T, Error>!
    Task.detached {
        do { result = .success(try await work()) } catch { result = .failure(error) }
        semaphore.signal()
    }
    semaphore.wait()
    do { return try result.get() } catch { fail("\(error)") }
}

let (adbPath, phone, serverPath) = blocking { () async throws -> (String, PhoneEndpoint, String) in
    let adb = AdbClient(adbPath: try ToolLocator.find("adb"))
    let scrcpy = try ToolLocator.find("scrcpy")
    let out = try await ProcessCommandRunner().run(scrcpy, ["--version"])
    guard let version = ScrcpyServer.parseClientVersion(out.stdout),
          let server = ScrcpyServer.locate(clientVersion: version) else {
        throw CommandError.notFound(tool: "scrcpy-server for the installed scrcpy client", searched: [])
    }
    return (adb.adbPath, try await PhoneLocator(adb: adb).locate(), server.path)
}

let args = Array(CommandLine.arguments.dropFirst())
let soloApp = args.first == "app" && args.count > 1 ? PhoneApp(name: args[1], package: args[1], isSystem: false) : nil
let mode: MirrorMode = args.first == "desk" || soloApp != nil ? .defaultDesk : .panelOff
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let window = MainActor.assumeIsolated {
    let window = MirrorWindowController(phone: phone, adbPath: adbPath, serverPath: serverPath, mode: mode, app: soloApp)
    window.onStatus = { fputs("\($0)\n", stderr) }
    window.onClose = { exit(0) }
    // No menu bar app here, so a lost stream retries on the endpoint it started with.
    window.onLost = { window.use(phone) }
    window.show()
    return window
}
app.run()
withExtendedLifetime(window) {}
