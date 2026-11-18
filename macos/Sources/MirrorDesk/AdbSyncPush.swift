import Foundation

/// A blocking byte stream. The real one is a socket to the adb server; tests use a script.
public protocol AdbByteStream: AnyObject {
    func write(_ data: Data) throws
    /// Reads exactly `count` bytes, or fewer if the peer closed.
    func read(_ count: Int) throws -> Data
    func close()
}

/// Pushes one file with adb's sync protocol and reports bytes sent. `adb push` prints progress
/// only to a terminal, so we speak the protocol ourselves.
public struct AdbSyncPush {
    public typealias Progress = (_ sent: Int64, _ total: Int64) -> Bool

    let serial: String
    let connect: () throws -> AdbByteStream
    /// Bytes per second to stay under, read before each chunk; nil sends at full speed.
    let rateLimit: () -> Int?

    public init(serial: String, rateLimit: @escaping () -> Int? = { nil },
                connect: @escaping () throws -> AdbByteStream = { try AdbSocket.connect() }) {
        self.serial = serial
        self.rateLimit = rateLimit
        self.connect = connect
    }

    /// Phone folder that scrcpy also drops files into.
    public static let downloadDir = "/sdcard/Download"

    /// Sends `file` to `remoteDir`. `progress` runs after each chunk; return false to cancel.
    /// Returns the remote path.
    @discardableResult
    public func push(_ file: URL, to remoteDir: String = downloadDir, progress: Progress) throws -> String {
        let remote = "\(remoteDir)/\(file.lastPathComponent)"
        guard let handle = try? FileHandle(forReadingFrom: file) else {
            throw AdbSyncError.localFile(file.path)
        }
        defer { try? handle.close() }
        let attrs = try? FileManager.default.attributesOfItem(atPath: file.path)
        let total = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = UInt32(((attrs?[.modificationDate] as? Date) ?? Date()).timeIntervalSince1970)

        let stream = try connect()
        defer { stream.close() }
        try host(stream, "host:transport:\(serial)")
        try host(stream, "sync:")
        try stream.write(AdbSyncWire.send(remotePath: remote))

        var sent: Int64 = 0
        var pacer = Pacer()
        while true {
            pacer.wait(rate: rateLimit())
            let chunk = try handle.read(upToCount: AdbSyncWire.maxChunk) ?? Data()
            if chunk.isEmpty { break }
            try stream.write(AdbSyncWire.data(chunk))
            sent += Int64(chunk.count)
            pacer.sent(chunk.count)
            // Closing mid-transfer makes adbd drop the partial file.
            if !progress(sent, total) { throw CancellationError() }
        }
        try stream.write(AdbSyncWire.done(mtime: mtime))
        try syncReply(stream)
        return remote
    }

    private func host(_ stream: AdbByteStream, _ service: String) throws {
        try stream.write(AdbSyncWire.hostRequest(service))
        let status = try readExactly(stream, 4, context: service)
        switch String(decoding: status, as: UTF8.self) {
        case "OKAY": return
        case "FAIL":
            let lenHex = String(decoding: try readExactly(stream, 4, context: service), as: UTF8.self)
            let len = Int(lenHex, radix: 16) ?? 0
            let message = String(decoding: try stream.read(len), as: UTF8.self)
            throw AdbSyncError.hostRefused(service: service, message: message)
        case let other:
            throw AdbSyncError.unexpectedReply(context: service, got: other)
        }
    }

    /// Sync reply, 8 bytes: `[0..4]` `OKAY` or `FAIL`, `[4..8]` u32 LE message length
    /// (0 for OKAY), followed by the message for FAIL.
    private func syncReply(_ stream: AdbByteStream) throws {
        let header = try readExactly(stream, 8, context: "sync DONE")
        let id = String(decoding: header.prefix(4), as: UTF8.self)
        let len = Int(AdbSyncWire.readU32LE(header.suffix(4)))
        switch id {
        case "OKAY": return
        case "FAIL":
            throw AdbSyncError.syncFailed(message: String(decoding: try stream.read(len), as: UTF8.self))
        default:
            throw AdbSyncError.unexpectedReply(context: "sync DONE", got: id)
        }
    }

    private func readExactly(_ stream: AdbByteStream, _ count: Int, context: String) throws -> Data {
        let data = try stream.read(count)
        guard data.count == count else {
            throw AdbSyncError.shortRead(context: context, expected: count, actual: data.count)
        }
        return data
    }
}

/// Keeps a push under a byte rate. adb carries every stream to the phone over one connection,
/// so a push at full Wi-Fi speed queues megabytes ahead of the mirror's video and the picture
/// stalls (Phase 2 hand test). Sleeping between chunks keeps that queue short.
struct Pacer {
    private var windowStart = Date()
    private var windowBytes = 0
    private var lastRate: Int?

    mutating func sent(_ bytes: Int) { windowBytes += bytes }

    /// Sleeps until the bytes sent in this window fit `rate`. A new rate starts a new window.
    mutating func wait(rate: Int?) {
        if rate != lastRate {
            lastRate = rate
            windowStart = Date()
            windowBytes = 0
        }
        guard let rate, rate > 0 else { return }
        let due = Double(windowBytes) / Double(rate)
        let elapsed = Date().timeIntervalSince(windowStart)
        if due > elapsed { Thread.sleep(forTimeInterval: due - elapsed) }
        // Restart the window each second so a slow stretch is not made up with a burst.
        if elapsed > 1 {
            windowStart = Date()
            windowBytes = 0
        }
    }
}

/// TCP socket to the local adb server.
public final class AdbSocket: AdbByteStream {
    private let fd: Int32

    private init(fd: Int32) { self.fd = fd }

    public static func connect(port: UInt16 = 5037) throws -> AdbSocket {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AdbSyncError.connectFailed(String(cString: strerror(errno))) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(fd)
            throw AdbSyncError.connectFailed(message)
        }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        return AdbSocket(fd: fd)
    }

    public func write(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n <= 0 { throw AdbSyncError.connectFailed(String(cString: strerror(errno))) }
                offset += n
            }
        }
    }

    public func read(_ count: Int) throws -> Data {
        var out = Data(count: count)
        var got = 0
        try out.withUnsafeMutableBytes { raw in
            while got < count {
                let n = Darwin.read(fd, raw.baseAddress! + got, count - got)
                if n == 0 { break }
                if n < 0 { throw AdbSyncError.connectFailed(String(cString: strerror(errno))) }
                got += n
            }
        }
        return out.prefix(got)
    }

    public func close() { Darwin.close(fd) }
}
