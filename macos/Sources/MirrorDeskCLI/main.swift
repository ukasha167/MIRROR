import Foundation
import MirrorDesk

// Scripted checks against a real phone. Each command prints PASS or FAIL and exits 0 or 1.
//
//   swift run mirror-desk locate              find the phone, switch it to adb tcpip
//   swift run mirror-desk clipboard-roundtrip phone clipboard both ways, Mac pasteboard untouched

let usage = "usage: mirror-desk locate | clipboard-roundtrip"

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

let args = CommandLine.arguments.dropFirst()
switch args.first {
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
