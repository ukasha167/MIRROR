import Foundation
import Network
import Darwin

/// Typed errors produced by `ScrcpyStreamClient`.
public enum ScrcpyStreamError: Error, Sendable, LocalizedError, CustomStringConvertible {
    case serverBinaryNotFound(searchedPaths: [String])
    case adbCommandFailed(arguments: [String], exitCode: Int32, stderr: String)
    case handshakeTimeout(reason: String)
    case processExitedPrematurely(exitCode: Int32, output: String)
    case networkFailure(String)

    public var errorDescription: String? { description }

    public var description: String {
        switch self {
        case .serverBinaryNotFound(let paths):
            return "scrcpy-server not found (searched: \(paths.joined(separator: ", ")))"
        case .adbCommandFailed(let args, let code, let err):
            return "adb \(args.joined(separator: " ")) failed (exit \(code)): \(err)"
        case .handshakeTimeout(let reason):
            return "scrcpy handshake timed out: \(reason)"
        case .processExitedPrematurely(let code, let out):
            return "scrcpy-server exited (code \(code)): \(out)"
        case .networkFailure(let msg):
            return "scrcpy socket failure: \(msg)"
        }
    }
}

/// Low-level ADB process, port-forwarding, and loopback socket helpers for `scrcpy-server`.
enum ScrcpyAdbTransport {
    static func resolveServerPath() throws -> String {
        var candidates: [String] = []
        if let bundlePath = Bundle.main.path(forResource: "scrcpy-server", ofType: nil) {
            candidates.append(bundlePath)
        }
        candidates.append("/opt/homebrew/share/scrcpy/scrcpy-server")
        candidates.append("/usr/local/share/scrcpy/scrcpy-server")
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            return path
        }
        throw ScrcpyStreamError.serverBinaryNotFound(searchedPaths: candidates)
    }

    static func allocateLoopbackPort() throws -> UInt16 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ScrcpyStreamError.networkFailure("Unable to allocate TCP socket")
        }
        defer { Darwin.close(fd) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            throw ScrcpyStreamError.networkFailure("Unable to bind ephemeral port")
        }

        var boundAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &len)
            }
        }
        guard nameResult == 0 else {
            throw ScrcpyStreamError.networkFailure("getsockname failed")
        }
        return UInt16(bigEndian: boundAddr.sin_port)
    }

    private final class OnceGate: @unchecked Sendable {
        private let lock = NSLock()
        private var consumed = false
        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if consumed { return false }
            consumed = true
            return true
        }
    }

    static func connectLoopback(port: UInt16, queue: DispatchQueue) async throws -> NWConnection {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw ScrcpyStreamError.networkFailure("Invalid loopback port \(port)")
        }
        let conn = NWConnection(host: "127.0.0.1", port: nwPort, using: .tcp)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let gate = OnceGate()
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if gate.claim() { cont.resume() }
                case .failed(let error):
                    if gate.claim() { cont.resume(throwing: ScrcpyStreamError.networkFailure(error.localizedDescription)) }
                case .cancelled:
                    if gate.claim() { cont.resume(throwing: ScrcpyStreamError.networkFailure("Loopback socket cancelled")) }
                default:
                    break
                }
            }
            conn.start(queue: queue)
        }
        return conn
    }

    static func receiveFirstBytes(on conn: NWConnection) async -> Data? {
        await withCheckedContinuation { cont in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    cont.resume(returning: data)
                } else if isComplete || error != nil {
                    cont.resume(returning: nil)
                } else {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    @discardableResult
    static func runAdbSync(adbPath: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        let outStr = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errStr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            throw ScrcpyStreamError.adbCommandFailed(arguments: arguments, exitCode: process.terminationStatus, stderr: errStr)
        }
        return outStr
    }

    @discardableResult
    static func runAdbAsync(adbPath: String, arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    cont.resume(returning: try runAdbSync(adbPath: adbPath, arguments: arguments))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }
}
