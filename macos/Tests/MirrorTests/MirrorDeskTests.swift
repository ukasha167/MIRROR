import Testing
import Foundation
@testable import MirrorDesk

/// Replays canned adb output keyed by the joined argument list.
final class ScriptedRunner: CommandRunning, @unchecked Sendable {
    var responses: [String: CommandResult]
    private(set) var calls: [[String]] = []
    private let lock = NSLock()

    init(_ responses: [String: CommandResult]) { self.responses = responses }

    func run(_ executable: String, _ arguments: [String]) async throws -> CommandResult {
        let response = lock.withLock {
            calls.append(arguments)
            return responses[arguments.joined(separator: " ")]
        }
        return response ?? CommandResult(exitCode: 1, stdout: "", stderr: "unscripted: \(arguments)")
    }
}

final class MemoryPhoneStore: SavedPhoneStore, @unchecked Sendable {
    var address: String?
    init(_ address: String? = nil) { self.address = address }
    func loadAddress() -> String? { address }
    func saveAddress(_ address: String) { self.address = address }
}

struct AdbParsingTests {
    @Test("Parses USB and Wi-Fi rows from adb devices -l")
    func parseDevices() {
        let out = """
        List of devices attached
        28161FDH300LZD         device usb:17825792X product:cheetah model:Pixel_7_Pro device:cheetah transport_id:5
        192.168.18.230:5555    device product:cheetah model:Pixel_7_Pro device:cheetah transport_id:6
        ZY22ABC                unauthorized usb:1-1 transport_id:7

        """
        let devices = AdbClient.parseDevices(out)
        #expect(devices.count == 3)
        #expect(devices[0] == AdbDevice(serial: "28161FDH300LZD", state: "device", model: "Pixel 7 Pro"))
        #expect(devices[0].transport == .usb)
        #expect(devices[1].transport == .wifi)
        #expect(!devices[2].isReady)
    }

    @Test("Reads the IPv4 address from ip addr output")
    func parseInet() {
        let out = """
        47: wlan0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc pfifo_fast state UP group default qlen 1000
            inet 192.168.18.230/24 brd 192.168.18.255 scope global dynamic wlan0
        """
        #expect(AdbClient.parseInetAddress(out) == "192.168.18.230")
        #expect(AdbClient.parseInetAddress("Device \"wlan0\" does not exist.") == nil)
    }

    @Test("Reads adb connect output, which exits 0 on failure too")
    func connectOutput() {
        #expect(AdbClient.connectSucceeded("connected to 192.168.18.230:5555"))
        #expect(AdbClient.connectSucceeded("already connected to 192.168.18.230:5555"))
        #expect(!AdbClient.connectSucceeded("failed to connect to '192.168.18.230:5555': Connection refused"))
        #expect(!AdbClient.connectSucceeded("cannot connect to 192.168.18.230:5555: No route to host"))
    }
}

struct PhoneLocatorTests {
    let usbRow = "List of devices attached\nSER1 device usb:1 model:Pixel_7_Pro\n"

    @Test("USB phone: saves its Wi-Fi address, switches to tcpip, returns the USB serial")
    func usbSwitchesToWifi() async throws {
        let runner = ScriptedRunner([
            "devices -l": CommandResult(exitCode: 0, stdout: usbRow),
            "-s SER1 shell ip -f inet addr show wlan0": CommandResult(exitCode: 0, stdout: "    inet 10.0.0.7/24 brd x\n"),
            "-s SER1 tcpip 5555": CommandResult(exitCode: 0, stdout: "restarting in TCP mode port: 5555\n"),
            "connect 10.0.0.7:5555": CommandResult(exitCode: 0, stdout: "connected to 10.0.0.7:5555\n"),
        ])
        let store = MemoryPhoneStore()
        let phone = try await PhoneLocator(adb: AdbClient(adbPath: "adb", runner: runner), store: store).locate()
        #expect(phone == PhoneEndpoint(serial: "SER1", transport: .usb, model: "Pixel 7 Pro"))
        #expect(store.address == "10.0.0.7")
        #expect(runner.calls.contains(["-s", "SER1", "tcpip", "5555"]))
    }

    @Test("USB phone already on Wi-Fi: no second tcpip restart")
    func usbAlreadyOnWifi() async throws {
        let runner = ScriptedRunner([
            "devices -l": CommandResult(exitCode: 0, stdout: usbRow + "10.0.0.7:5555 device model:Pixel_7_Pro\n"),
            "-s SER1 shell ip -f inet addr show wlan0": CommandResult(exitCode: 0, stdout: "    inet 10.0.0.7/24\n"),
        ])
        _ = try await PhoneLocator(adb: AdbClient(adbPath: "adb", runner: runner), store: MemoryPhoneStore()).locate()
        #expect(!runner.calls.contains { $0.contains("tcpip") })
    }

    @Test("No cable: reconnects to the saved address")
    func savedAddress() async throws {
        let runner = ScriptedRunner([
            "devices -l": CommandResult(exitCode: 0, stdout: "List of devices attached\n"),
            "connect 10.0.0.7:5555": CommandResult(exitCode: 0, stdout: "connected to 10.0.0.7:5555\n"),
        ])
        let phone = try await PhoneLocator(adb: AdbClient(adbPath: "adb", runner: runner), store: MemoryPhoneStore("10.0.0.7")).locate()
        #expect(phone.serial == "10.0.0.7:5555")
        #expect(phone.transport == .wifi)
    }

    @Test("Unauthorized USB phone reports the prompt to accept")
    func unauthorized() async {
        let runner = ScriptedRunner(["devices -l": CommandResult(exitCode: 0, stdout: "x\nSER1 unauthorized usb:1\n")])
        await #expect(throws: PhoneLocatorError.unauthorized(serial: "SER1")) {
            try await PhoneLocator(adb: AdbClient(adbPath: "adb", runner: runner), store: MemoryPhoneStore()).locate()
        }
    }

    @Test("Nothing attached and nothing saved")
    func noPhone() async {
        let runner = ScriptedRunner(["devices -l": CommandResult(exitCode: 0, stdout: "List of devices attached\n")])
        await #expect(throws: PhoneLocatorError.noPhone) {
            try await PhoneLocator(adb: AdbClient(adbPath: "adb", runner: runner), store: MemoryPhoneStore()).locate()
        }
    }
}

struct ScrcpyLaunchTests {
    let server = ScrcpyServer(path: "/tmp/scrcpy-server-v4.1", version: "4.1")

    @Test("Desk mode asks for a new display and keeps apps after close")
    func deskArgs() {
        let config = ScrcpyLaunchConfig(serial: "SER1", mode: .desk(width: 1600, height: 1000, dpi: 200), server: server, windowTitle: "Pixel")
        #expect(config.arguments.contains("--new-display=1600x1000/200"))
        #expect(config.arguments.contains("--no-vd-destroy-content"))
        #expect(config.arguments.contains("--serial=SER1"))
        #expect(!config.arguments.contains("--turn-screen-off"))
        #expect(config.environment["SCRCPY_SERVER_PATH"] == "/tmp/scrcpy-server-v4.1")
    }

    @Test("Panel-off mirror turns the panel off and stretches the screen timeout")
    func panelOffArgs() {
        let args = ScrcpyLaunchConfig(serial: "SER1", mode: .panelOff, server: server, windowTitle: "Pixel").arguments
        #expect(args.contains("--turn-screen-off"))
        #expect(args.contains("--screen-off-timeout=3600"))
        #expect(!args.contains { $0.hasPrefix("--new-display") })
    }

    @Test("Client version comes from scrcpy --version")
    func clientVersion() {
        #expect(ScrcpyServer.parseClientVersion("scrcpy 4.1 <https://github.com/Genymobile/scrcpy>\n\nDependencies") == "4.1")
        #expect(ScrcpyServer.parseClientVersion("command not found") == nil)
    }

    @Test("Server lookup only accepts the client's version")
    func serverLookup() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("build"), withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("build/scrcpy-server-v4.1"))
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(ScrcpyServer.locate(clientVersion: "4.1", environment: [:], bundleResources: nil, repoRoot: dir.path)?.version == "4.1")
        #expect(ScrcpyServer.locate(clientVersion: "5.0.1", environment: [:], bundleResources: nil, repoRoot: dir.path) == nil)
    }
}

struct ScrcpyWireTests {
    @Test("SET_CLIPBOARD byte layout")
    func setClipboard() {
        let data = ScrcpyControlWire.setClipboard("hé", sequence: 0x0102, paste: true)
        #expect(Array(data) == [9, 0, 0, 0, 0, 0, 0, 1, 2, 1, 0, 0, 0, 3, 0x68, 0xC3, 0xA9])
    }

    @Test("Truncation never splits a UTF-8 character")
    func truncation() {
        let cut = ScrcpyControlWire.truncatedUTF8("aé", maxBytes: 2) // "é" is 2 bytes
        #expect(Array(cut) == [0x61])
    }

    @Test("Parser joins messages split across reads")
    func parserSplit() throws {
        var parser = ScrcpyDeviceMessageParser()
        let full: [UInt8] = [0, 0, 0, 0, 2, 0x68, 0x69] + [1, 0, 0, 0, 0, 0, 0, 0, 7]
        let r1 = try parser.feed(Data(full[0..<3]))
        #expect(r1.isEmpty)
        let messages = try parser.feed(Data(full[3...]))
        #expect(messages == [.clipboard("hi"), .ackClipboard(sequence: 7)])
    }

    @Test("Parser rejects unknown types with the type in the error")
    func parserUnknown() {
        #expect(throws: ScrcpyWireError.unknownDeviceMessageType(0x50)) {
            var parser = ScrcpyDeviceMessageParser()
            _ = try parser.feed(Data([0x50, 0x69]))
        }
    }

    @Test("Parser rejects oversized clipboard lengths")
    func parserOversize() {
        #expect(throws: ScrcpyWireError.self) {
            var parser = ScrcpyDeviceMessageParser()
            _ = try parser.feed(Data([0, 0xFF, 0xFF, 0xFF, 0xFF]))
        }
    }
}

struct ClipboardSyncTests {
    @Test("Mac copy goes to the phone once and does not echo back")
    func noEcho() {
        var state = ClipboardSyncState()
        let r2 = state.macChanged(to: "one")
        #expect(r2 == "one")
        let r3 = state.phoneChanged(to: "one")
        #expect(r3 == false) // phone poll reports what we just set
        let r4 = state.macChanged(to: "one")
        #expect(r4 == nil)
    }

    @Test("Phone copy reaches the Mac, then a new Mac copy goes back")
    func phoneThenMac() {
        var state = ClipboardSyncState()
        let r5 = state.phoneChanged(to: "code 123456")
        #expect(r5)
        let r6 = state.macChanged(to: "code 123456")
        #expect(r6 == nil)
        let r7 = state.macChanged(to: "other")
        #expect(r7 == "other")
    }

    @Test("Empty and nil text are ignored")
    func empty() {
        var state = ClipboardSyncState()
        let r8 = state.macChanged(to: nil)
        #expect(r8 == nil)
        let r9 = state.macChanged(to: "")
        #expect(r9 == nil)
        let r10 = state.phoneChanged(to: "")
        #expect(!r10)
    }

    @Test("Password manager items are not synced")
    func concealed() {
        #expect(PasteboardMarkers.shouldSkip(types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]))
        #expect(!PasteboardMarkers.shouldSkip(types: ["public.utf8-plain-text"]))
    }
}
