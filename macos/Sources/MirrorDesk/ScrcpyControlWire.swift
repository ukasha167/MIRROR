import Foundation

/// scrcpy 4.1 control-socket messages that the clipboard bridge sends and reads.
/// All integers are big-endian (Java `DataOutputStream`).
public enum ScrcpyControlWire {
    /// Largest message the server accepts or sends (`ControlMessageReader.MESSAGE_MAX_SIZE`).
    public static let messageMaxSize = 1 << 18
    /// SET_CLIPBOARD header: type (1) + sequence (8) + paste (1) + length (4).
    public static let setClipboardHeaderSize = 14
    public static let setClipboardTextMax = messageMaxSize - setClipboardHeaderSize

    /// Encodes a SET_CLIPBOARD control message (Mac to phone).
    ///
    /// Byte layout:
    /// ```
    /// offset 0   u8      type = 9
    /// offset 1   u64 BE  sequence (0 = no ACK wanted)
    /// offset 9   u8      paste (1 = also inject a paste key event)
    /// offset 10  u32 BE  text length in bytes (n)
    /// offset 14  n bytes UTF-8 text
    /// ```
    /// Text longer than `setClipboardTextMax` bytes is cut at a UTF-8 character boundary.
    public static func setClipboard(_ text: String, sequence: UInt64 = 0, paste: Bool = false) -> Data {
        let raw = truncatedUTF8(text, maxBytes: setClipboardTextMax)
        var data = Data(capacity: setClipboardHeaderSize + raw.count)
        data.append(9)
        appendBigEndian(sequence, to: &data)
        data.append(paste ? 1 : 0)
        appendBigEndian(UInt32(raw.count), to: &data)
        data.append(raw)
        return data
    }

    static func truncatedUTF8(_ text: String, maxBytes: Int) -> Data {
        let raw = Data(text.utf8)
        if raw.count <= maxBytes { return raw }
        var end = maxBytes
        // Step back over UTF-8 continuation bytes (10xxxxxx) so the cut lands on a character start.
        while end > 0 && (raw[end] & 0xC0) == 0x80 { end -= 1 }
        return raw.prefix(end)
    }

    private static func appendBigEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }
}

/// A message the scrcpy server sends to the client on the control socket.
public enum ScrcpyDeviceMessage: Equatable, Sendable {
    case clipboard(String)
    case ackClipboard(sequence: UInt64)
    case uhidOutput(id: UInt16, data: Data)
}

public enum ScrcpyWireError: Error, Equatable, CustomStringConvertible {
    case unknownDeviceMessageType(UInt8)
    case lengthTooLarge(messageType: UInt8, declared: Int, max: Int)
    case invalidUTF8(messageType: UInt8, length: Int)

    public var description: String {
        switch self {
        case .unknownDeviceMessageType(let type):
            return "unknown device message type \(type)"
        case .lengthTooLarge(let type, let declared, let max):
            return "device message type \(type) declares \(declared) bytes, max is \(max)"
        case .invalidUTF8(let type, let length):
            return "device message type \(type) carries \(length) bytes that are not valid UTF-8"
        }
    }
}

/// Splits the server-to-client control stream into messages. Feed it bytes as they arrive;
/// it keeps partial messages until the rest shows up.
///
/// Byte layouts (all big-endian):
/// ```
/// CLIPBOARD      offset 0 u8 type=0 | offset 1 u32 length n | offset 5 n bytes UTF-8
/// ACK_CLIPBOARD  offset 0 u8 type=1 | offset 1 u64 sequence
/// UHID_OUTPUT    offset 0 u8 type=2 | offset 1 u16 id | offset 3 u16 size n | offset 5 n bytes
/// ```
public struct ScrcpyDeviceMessageParser {
    private var buffer = Data()

    public init() {}

    public mutating func feed(_ bytes: Data) throws -> [ScrcpyDeviceMessage] {
        buffer.append(bytes)
        var messages: [ScrcpyDeviceMessage] = []
        while let (message, consumed) = try parseOne() {
            messages.append(message)
            buffer.removeFirst(consumed)
        }
        // Rebase so indices start at 0 again after removeFirst.
        buffer = Data(buffer)
        return messages
    }

    private func parseOne() throws -> (ScrcpyDeviceMessage, Int)? {
        let b = buffer
        guard let type = b.first else { return nil }
        let base = b.startIndex
        switch type {
        case 0:
            guard b.count >= 5 else { return nil }
            let length = Int(readUInt32(b, at: base + 1))
            let max = ScrcpyControlWire.messageMaxSize - 5
            guard length <= max else {
                throw ScrcpyWireError.lengthTooLarge(messageType: type, declared: length, max: max)
            }
            guard b.count >= 5 + length else { return nil }
            let payload = b.subdata(in: (base + 5)..<(base + 5 + length))
            guard let text = String(data: payload, encoding: .utf8) else {
                throw ScrcpyWireError.invalidUTF8(messageType: type, length: length)
            }
            return (.clipboard(text), 5 + length)
        case 1:
            guard b.count >= 9 else { return nil }
            var seq: UInt64 = 0
            for i in 0..<8 { seq = (seq << 8) | UInt64(b[base + 1 + i]) }
            return (.ackClipboard(sequence: seq), 9)
        case 2:
            guard b.count >= 5 else { return nil }
            let id = UInt16(b[base + 1]) << 8 | UInt16(b[base + 2])
            let size = Int(UInt16(b[base + 3]) << 8 | UInt16(b[base + 4]))
            guard b.count >= 5 + size else { return nil }
            return (.uhidOutput(id: id, data: b.subdata(in: (base + 5)..<(base + 5 + size))), 5 + size)
        default:
            throw ScrcpyWireError.unknownDeviceMessageType(type)
        }
    }

    private func readUInt32(_ data: Data, at index: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { ($0 << 8) | UInt32(data[index + $1]) }
    }
}
