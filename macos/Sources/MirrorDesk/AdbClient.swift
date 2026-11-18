import Foundation

public struct AdbDevice: Equatable, Sendable {
    public enum Transport: Equatable, Sendable { case usb, wifi }

    public var serial: String
    /// `device`, `unauthorized`, `offline`, ...
    public var state: String
    public var model: String?

    public var transport: Transport {
        // adb names TCP devices "<ip>:<port>"; USB devices use the hardware serial.
        serial.contains(":") || serial.hasPrefix("adb-") ? .wifi : .usb
    }

    public var isReady: Bool { state == "device" }
}

public struct AdbMdnsService: Equatable, Sendable {
    /// `adb-<hardware serial>-<random>`.
    public var instance: String
    public var host: String
    public var port: Int
    public var wirelessDebugging: Bool
}

/// Thin wrapper over the `adb` command line. Parsing lives in static functions so tests can
/// feed captured output without a phone.
public struct AdbClient: Sendable {
    public let adbPath: String
    let runner: any CommandRunning

    public init(adbPath: String, runner: any CommandRunning = ProcessCommandRunner()) {
        self.adbPath = adbPath
        self.runner = runner
    }

    @discardableResult
    func adb(_ args: [String]) async throws -> String {
        let result = try await runner.run(adbPath, args)
        guard result.exitCode == 0 else {
            throw CommandError.failed(command: "adb " + args.joined(separator: " "), exitCode: result.exitCode, stderr: result.stderr)
        }
        return result.stdout
    }

    public func devices() async throws -> [AdbDevice] {
        Self.parseDevices(try await adb(["devices", "-l"]))
    }

    /// The phone's IPv4 address on Wi-Fi, or nil when Wi-Fi is off.
    public func wifiAddress(serial: String) async throws -> String? {
        Self.parseInetAddress(try await adb(["-s", serial, "shell", "ip", "-f", "inet", "addr", "show", "wlan0"]))
    }

    /// Restarts adbd on the phone listening on TCP. Lasts until the phone reboots.
    public func enableTcpip(serial: String, port: Int) async throws {
        try await adb(["-s", serial, "tcpip", String(port)])
    }

    /// `adb connect` exits 0 even when it fails, so read its output.
    public func connect(host: String, port: Int) async throws -> Bool {
        let out = try await adb(["connect", "\(host):\(port)"])
        return Self.connectSucceeded(out)
    }

    /// Phones adb's mDNS browser has seen on the LAN.
    public func mdnsServices() async throws -> [AdbMdnsService] {
        Self.parseMdnsServices(try await adb(["mdns", "services"]))
    }

    public func push(serial: String, local: String, remote: String) async throws {
        try await adb(["-s", serial, "push", local, remote])
    }

    public func forward(serial: String, localPort: UInt16, remoteSocket: String) async throws {
        try await adb(["-s", serial, "forward", "tcp:\(localPort)", remoteSocket])
    }

    public func removeForward(serial: String, localPort: UInt16) async throws {
        try await adb(["-s", serial, "forward", "--remove", "tcp:\(localPort)"])
    }

    // MARK: - Parsers

    /// Parses `adb devices -l`, for example:
    /// ```
    /// List of devices attached
    /// 28161FDH300LZD         device usb:17825792X product:cheetah model:Pixel_7_Pro device:cheetah transport_id:4
    /// 192.168.18.230:5555    device product:cheetah model:Pixel_7_Pro device:cheetah transport_id:5
    /// ```
    public static func parseDevices(_ output: String) -> [AdbDevice] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 2, !line.hasPrefix("List of devices"), !line.hasPrefix("*") else { return nil }
            let model = fields.first { $0.hasPrefix("model:") }
                .map { String($0.dropFirst("model:".count)).replacingOccurrences(of: "_", with: " ") }
            return AdbDevice(serial: fields[0], state: fields[1], model: model)
        }
    }

    /// Parses `adb mdns services`, for example:
    /// ```
    /// List of discovered mdns services
    /// adb-28161FDH300LZD-oWgbVo	_adb._tcp	192.168.18.230:5555
    /// adb-28161FDH300LZD-oWgbVo	_adb-tls-connect._tcp	192.168.18.230:37155
    /// ```
    /// `_adb-tls-connect` is Android's Wireless debugging; `_adb` is `adb tcpip` mode.
    /// Pairing services (`_adb-tls-pairing`) are skipped: connecting needs a code.
    public static func parseMdnsServices(_ output: String) -> [AdbMdnsService] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 3, fields[1] == "_adb._tcp" || fields[1] == "_adb-tls-connect._tcp",
                  let colon = fields[2].lastIndex(of: ":"),
                  let port = Int(fields[2][fields[2].index(after: colon)...]) else { return nil }
            return AdbMdnsService(instance: fields[0], host: String(fields[2][..<colon]), port: port,
                                  wirelessDebugging: fields[1] == "_adb-tls-connect._tcp")
        }
        // Wireless debugging first: it survives reboots once the phone turns it back on.
        .sorted { $0.wirelessDebugging && !$1.wirelessDebugging }
    }

    /// Pulls the address out of `ip -f inet addr show wlan0` (`inet 192.168.18.230/24 brd ...`).
    public static func parseInetAddress(_ output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2, fields[0] == "inet" else { continue }
            return fields[1].split(separator: "/").first.map(String.init)
        }
        return nil
    }

    /// `adb connect` prints "connected to host:port" or "already connected to host:port" on success,
    /// and "failed to connect ..." or "cannot connect ..." otherwise.
    public static func connectSucceeded(_ output: String) -> Bool {
        let text = output.lowercased()
        return text.contains("connected to") && !text.contains("failed") && !text.contains("cannot")
    }
}
