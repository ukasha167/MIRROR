import Foundation
import Darwin

public enum ControlSessionError: Error, CustomStringConvertible {
    case socket(String)
    case serverDidNotStart(output: String)

    public var description: String {
        switch self {
        case .socket(let message): return "control socket: \(message)"
        case .serverDidNotStart(let output): return "scrcpy-server did not start: \(output)"
        }
    }
}

/// A scrcpy-server with video and audio off and only the control socket open.
/// The clipboard bridge uses it to exchange SET_CLIPBOARD and CLIPBOARD messages.
///
/// Setup, in order:
/// 1. `adb push` the server to `/data/local/tmp/mirror-scrcpy-server.jar` (its own name, so a
///    scrcpy window pushing `scrcpy-server.jar` at the same time cannot clobber it).
/// 2. `adb forward tcp:<port> localabstract:scrcpy_<scid as 8 hex digits>`.
/// 3. Start `app_process` through a long-running `adb shell`.
/// 4. Connect to 127.0.0.1:<port>. With `tunnel_forward=true` the server sends one dummy byte
///    first; adb accepts and then closes the socket while the server is not listening yet, so retry.
public final class ScrcpyControlSession: @unchecked Sendable {
    public static let remoteJar = "/data/local/tmp/mirror-scrcpy-server.jar"

    private let adb: AdbClient
    private let serial: String
    private let server: ScrcpyServer
    private let scid = UInt32.random(in: 1..<0x7FFF_FFFF)
    private var port: UInt16 = 0
    private var shell: Process?
    private var fd: Int32 = -1
    private let writeLock = NSLock()
    private var parser = ScrcpyDeviceMessageParser()

    public var onMessage: (@Sendable (ScrcpyDeviceMessage) -> Void)?
    public var onClose: (@Sendable (String) -> Void)?

    public init(adb: AdbClient, serial: String, server: ScrcpyServer) {
        self.adb = adb
        self.serial = serial
        self.server = server
    }

    var socketName: String { String(format: "localabstract:scrcpy_%08x", scid) }

    var serverArguments: [String] {
        [
            "-s", serial, "shell",
            "CLASSPATH=\(Self.remoteJar)", "app_process", "/", "com.genymobile.scrcpy.Server", server.version,
            String(format: "scid=%08x", scid), "log_level=info",
            "video=false", "audio=false", "control=true",
            "tunnel_forward=true", "send_device_meta=false", "cleanup=false",
        ]
    }

    public func start() async throws {
        try await adb.push(serial: serial, local: server.path, remote: Self.remoteJar)
        port = try Self.freeLoopbackPort()
        try await adb.forward(serial: serial, localPort: port, remoteSocket: socketName)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: adb.adbPath)
        process.arguments = serverArguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        shell = process

        for _ in 0..<50 {
            if !process.isRunning { break }
            if let connected = try? Self.connectAndReadDummyByte(port: port) {
                fd = connected
                startReader()
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        stop()
        let output = String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self)
        throw ControlSessionError.serverDidNotStart(output: output)
    }

    public func send(_ data: Data) {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard fd >= 0 else { return }
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.send(fd, raw.baseAddress! + offset, raw.count - offset, 0)
                if n <= 0 { return }
                offset += n
            }
        }
    }

    public func stop() {
        writeLock.lock()
        if fd >= 0 { Darwin.shutdown(fd, SHUT_RDWR) }
        writeLock.unlock()
        if let shell, shell.isRunning { shell.terminate() }
        shell = nil
        let adb = self.adb, serial = self.serial, port = self.port
        if port != 0 { Task { try? await adb.removeForward(serial: serial, localPort: port) } }
    }

    private func startReader() {
        let socket = fd
        let thread = Thread { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 65_536)
            var reason = "server closed the connection"
            while true {
                let n = Darwin.recv(socket, &buffer, buffer.count, 0)
                if n <= 0 { break }
                guard let self else { return }
                do {
                    for message in try self.parser.feed(Data(buffer[0..<n])) { self.onMessage?(message) }
                } catch {
                    reason = "\(error)"
                    break
                }
            }
            guard let self else { return }
            self.writeLock.lock()
            Darwin.close(socket)
            self.fd = -1
            self.writeLock.unlock()
            self.onClose?(reason)
        }
        thread.name = "scrcpy-control-reader"
        thread.start()
    }

    // MARK: - Sockets

    static func freeLoopbackPort() throws -> UInt16 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlSessionError.socket("socket() failed: errno \(errno)") }
        defer { Darwin.close(fd) }
        var addr = loopback(port: 0)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, len) == 0 && Darwin.getsockname(fd, $0, &len) == 0
            }
        }
        guard ok else { throw ControlSessionError.socket("bind failed: errno \(errno)") }
        return UInt16(bigEndian: addr.sin_port)
    }

    static func connectAndReadDummyByte(port: UInt16) throws -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlSessionError.socket("socket() failed: errno \(errno)") }
        var addr = loopback(port: port)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        var byte: UInt8 = 0
        guard connected, Darwin.recv(fd, &byte, 1, 0) == 1 else {
            Darwin.close(fd)
            throw ControlSessionError.socket("server not listening yet on port \(port)")
        }
        return fd
    }

    private static func loopback(port: UInt16) -> sockaddr_in {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return addr
    }
}
