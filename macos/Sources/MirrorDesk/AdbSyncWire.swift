import Foundation

/// Byte formats for talking to the adb server (`127.0.0.1:5037`) and its file sync service.
public enum AdbSyncWire {
    /// Largest DATA chunk the sync service accepts.
    public static let maxChunk = 64 * 1024

    /// Host service request: 4 ASCII hex digits giving the payload length, then the payload.
    /// Example: `"000chost:version"`.
    public static func hostRequest(_ service: String) -> Data {
        let body = Data(service.utf8)
        return Data(String(format: "%04x", body.count).utf8) + body
    }

    /// Sync request header, 8 bytes:
    /// `[0..4]` command id (ASCII, e.g. `SEND`, `DATA`, `DONE`), `[4..8]` u32 little-endian
    /// argument (a length for SEND/DATA, a Unix mtime for DONE).
    public static func syncHeader(_ id: String, _ value: UInt32) -> Data {
        precondition(id.utf8.count == 4)
        var le = value.littleEndian
        return Data(id.utf8) + Data(bytes: &le, count: 4)
    }

    /// `SEND` header plus `"<remote path>,<octal mode as decimal>"`.
    public static func send(remotePath: String, mode: UInt32 = 0o644) -> Data {
        let spec = Data("\(remotePath),\(0o100000 | mode)".utf8)
        return syncHeader("SEND", UInt32(spec.count)) + spec
    }

    public static func data(_ chunk: Data) -> Data {
        syncHeader("DATA", UInt32(chunk.count)) + chunk
    }

    public static func done(mtime: UInt32) -> Data {
        syncHeader("DONE", mtime)
    }

    public static func readU32LE(_ bytes: Data) -> UInt32 {
        bytes.prefix(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
    }
}

public enum AdbSyncError: Error, Equatable, CustomStringConvertible {
    case connectFailed(String)
    case hostRefused(service: String, message: String)
    case syncFailed(message: String)
    /// Reply id was not OKAY or FAIL.
    case unexpectedReply(context: String, got: String)
    case shortRead(context: String, expected: Int, actual: Int)
    case localFile(String)

    public var description: String {
        switch self {
        case .connectFailed(let m): "Could not reach the adb server: \(m)"
        case .hostRefused(let s, let m): "adb refused \(s): \(m)"
        case .syncFailed(let m): "Phone refused the file: \(m)"
        case .unexpectedReply(let c, let g): "Unexpected adb reply during \(c): \(g)"
        case .shortRead(let c, let e, let a): "adb closed during \(c): wanted \(e) bytes, got \(a)"
        case .localFile(let m): "Could not read the file: \(m)"
        }
    }
}
