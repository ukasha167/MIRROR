import Foundation
import MirrorDesk
import MirrorRenderer
import CoreVideo

// Scripted checks against a real phone. Each command prints PASS or FAIL and exits 0 or 1.
//
//   swift run mirror-desk locate              find the phone, switch it to adb tcpip
//   swift run mirror-desk clipboard-roundtrip phone clipboard both ways, Mac pasteboard untouched
//   swift run mirror-desk stream-check [desk [package]]  native decoder gets frames for 5 s;
//                                             with a package, it opens on the virtual display
//   swift run mirror-desk push <file>         adb sync push to Download/ with progress

let usage = "usage: mirror-desk locate | clipboard-roundtrip | stream-check [desk [package]] | push <file>"

func fail(_ message: String) -> Never {
    print("FAIL: \(message)")
    exit(1)
}

func makeAdb() -> AdbClient {
    do { return AdbClient(adbPath: try ToolLocator.find("adb")) } catch { fail("\(error)") }
}

func makeServer() async -> ScrcpyServer {
    guard let scrcpy = try? ToolLocator.find("scrcpy"),
          let out = try? await ProcessCommandRunner().run(scrcpy, ["--version"]),
          let version = ScrcpyServer.parseClientVersion(out.stdout) else {
        fail("scrcpy client not found")
    }
    guard let server = ScrcpyServer.locate(clientVersion: version) else {
        fail("no scrcpy-server-v\(version); run scripts/build-scrcpy-server.sh")
    }
    return server
}

/// Waits for `want` to arrive as a CLIPBOARD message on `session`.
final class ClipboardWaiter: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let want: String
    init(session: ScrcpyControlSession, want: String) {
        self.want = want
        session.onMessage = { [self] message in
            if case .clipboard(let text) = message, text == self.want { semaphore.signal() }
        }
    }
    func wait(seconds: Double) -> Bool { semaphore.wait(timeout: .now() + seconds) == .success }
}

final class LogBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""
    func append(_ s: String) { lock.withLock { value += s } }
    var text: String { lock.withLock { value } }
}

/// Counts decoded frames from a native session.
final class FrameCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var size = CGSize.zero
    func add(_ s: CGSize) { lock.withLock { count += 1; size = s } }
    var snapshot: (Int, CGSize) { lock.withLock { (count, size) } }
}

let args = CommandLine.arguments.dropFirst()
switch args.first {
case "push":
    guard let path = args.dropFirst().first else { fail(usage) }
    let phone: PhoneEndpoint
    do { phone = try await PhoneLocator(adb: makeAdb()).locate() } catch { fail("\(error)") }
    let started = Date()
    var lastPercent = -1
    do {
        let remote = try AdbSyncPush(serial: phone.serial).push(URL(fileURLWithPath: path)) { sent, total in
            let percent = total > 0 ? Int(sent * 100 / total) : 100
            if percent / 10 != lastPercent / 10 { print("\(percent)%"); lastPercent = percent }
            return true
        }
        let seconds = Date().timeIntervalSince(started)
        print("PASS: \(remote) in \(String(format: "%.1f", seconds)) s via \(phone.transport)")
    } catch { fail("\(error)") }

case "stream-check":
    let adb = makeAdb()
    let server = await makeServer()
    let phone: PhoneEndpoint
    do { phone = try await PhoneLocator(adb: adb).locate() } catch { fail("\(error)") }
    let mode: MirrorMode = args.dropFirst().first == "desk" ? .defaultDesk : .panelOff
    let config = NativeMirrorConfig(mode: mode, serverPath: server.path)
    let client = ScrcpyStreamClient()
    let counter = FrameCounter()
    client.onPixelBuffer = { buffer, _ in
        counter.add(CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)))
    }
    client.onStateChanged = { print("state: \($0)") }
    let displayLog = LogBuffer()
    client.onServerLog = { displayLog.append($0) }
    do {
        try await client.start(serial: phone.serial, adbPath: adb.adbPath, maxSize: config.maxSize,
                               maxFps: NativeMirrorConfig.maxFps, options: config.streamOptions)
    } catch { fail("\(error)") }
    try? await Task.sleep(nanoseconds: 3_000_000_000)
    if let package = args.dropFirst(2).first {
        guard let id = PhoneApps.virtualDisplayID(inServerLog: displayLog.text) else { fail("no virtual display id in server log") }
        client.sendControl(ScrcpyControlEncoder.startApp(packageName: package))
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        let out = try? await ProcessCommandRunner().run(adb.adbPath, ["-s", phone.serial, "shell", "dumpsys", "activity", "activities"])
        // Tasks are listed per display; find this display's block and check the app is in it.
        let dump = out?.stdout ?? ""
        let block = dump.components(separatedBy: "Display #").first { $0.hasPrefix("\(id) ") } ?? ""
        if !block.contains(package) { fail("\(package) not on display \(id)") }
        print("PASS: \(package) opened on virtual display \(id)")
    }
    try? await Task.sleep(nanoseconds: 2_000_000_000)
    client.stop()
    let (frames, size) = counter.snapshot
    // A still screen sends few frames; any decoded frame proves the path works.
    if frames == 0 { fail("no frames decoded") }
    print("PASS: \(frames) frames at \(Int(size.width))x\(Int(size.height)) via \(phone.transport)")

case "locate":
    do {
        let phone = try await PhoneLocator(adb: makeAdb()).locate()
        print("PASS: \(phone.model) via \(phone.transport) as \(phone.serial)")
        if let address = UserDefaultsPhoneStore().loadAddress() { print("saved Wi-Fi address: \(address)") }
    } catch {
        fail("\(error)")
    }

case "clipboard-roundtrip":
    let adb = makeAdb()
    let server = await makeServer()
    let phone: PhoneEndpoint
    do { phone = try await PhoneLocator(adb: adb).locate() } catch { fail("\(error)") }

    // Two sessions: A stands in for the Mac bridge, B makes a change "on the phone".
    let a = ScrcpyControlSession(adb: adb, serial: phone.serial, server: server)
    let b = ScrcpyControlSession(adb: adb, serial: phone.serial, server: server)
    do {
        try await a.start()
        try await b.start()
    } catch {
        fail("\(error)")
    }
    defer { a.stop(); b.stop() }

    let toA = "mirror-check-\(UInt32.random(in: 0..<UInt32.max))"
    let waitA = ClipboardWaiter(session: a, want: toA)
    b.send(ScrcpyControlWire.setClipboard(toA))
    guard waitA.wait(seconds: 4) else { fail("phone-to-Mac: session A never saw \(toA)") }
    print("phone-to-Mac ok")

    let toB = "mirror-check-\(UInt32.random(in: 0..<UInt32.max))"
    let waitB = ClipboardWaiter(session: b, want: toB)
    a.send(ScrcpyControlWire.setClipboard(toB))
    guard waitB.wait(seconds: 4) else { fail("Mac-to-phone: session B never saw \(toB)") }
    print("Mac-to-phone ok")
    print("PASS: clipboard round trip on \(phone.serial)")

default:
    print(usage)
    exit(2)
}
