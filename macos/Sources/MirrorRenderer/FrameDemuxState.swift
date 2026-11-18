import Foundation

/// Parsed metadata for a scrcpy video or audio packet.
public struct ScrcpyFramePacket: Sendable, Equatable {
    public let ptsMicroseconds: UInt64
    public let isConfig: Bool
    public let isKeyframe: Bool
    public let payload: Data

    public init(ptsMicroseconds: UInt64, isConfig: Bool, isKeyframe: Bool, payload: Data) {
        self.ptsMicroseconds = ptsMicroseconds
        self.isConfig = isConfig
        self.isKeyframe = isKeyframe
        self.payload = payload
    }
}

/// Errors occurring during frame demuxing.
public enum FrameDemuxError: Error, Sendable, CustomStringConvertible {
    case invalidHeaderSize(expected: Int, actual: Int)
    case payloadTooLarge(size: UInt32, maxSize: UInt32)

    public var description: String {
        switch self {
        case .invalidHeaderSize(let expected, let actual):
            return "FrameDemuxError: Expected \(expected) header bytes, got \(actual)"
        case .payloadTooLarge(let size, let maxSize):
            return "FrameDemuxError: Frame payload size \(size) exceeds maximum \(maxSize)"
        }
    }
}

/// Deterministic scrcpy 12-byte frame-header parser and stream demuxing state machine.
///
/// ### scrcpy Frame Header Wire Layout (12 bytes, Big-Endian):
///
/// ```
///  0                   1                   2                   3
///  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |C|K|                     PTS (bits 0..61)                     | (bytes 0..7)
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |                          packet_size                          | (bytes 8..11)
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// ```
/// - **Bit 63 (`0x8000000000000000`)**: `is_config` (contains VPS, SPS, PPS parameter sets)
/// - **Bit 62 (`0x4000000000000000`)**: `is_keyframe` (IDR slice)
/// - **Bits 0..61 (`0x3FFFFFFFFFFFFFFF`)**: `pts` (presentation timestamp in microseconds)
/// - **Bytes 8..11**: `packet_size` (`u32` payload size in bytes)
public final class FrameDemuxStateMachine: @unchecked Sendable {
    public static let headerSize = 12
    public static let maxPayloadSize: UInt32 = 16 * 1024 * 1024 // 16 MB max frame size

    private enum State {
        case awaitingHeader
        case awaitingPayload(pts: UInt64, isConfig: Bool, isKeyframe: Bool, size: Int)
    }

    private var state: State = .awaitingHeader
    private var buffer = Data()

    public init() {}

    /// Resets the internal stream buffer and state.
    public func reset() {
        state = .awaitingHeader
        buffer.removeAll(keepingCapacity: true)
    }

    /// Feeds incoming socket chunk and extracts completed frame packets.
    public func feed(data: Data) throws -> [ScrcpyFramePacket] {
        buffer.append(data)
        var frames: [ScrcpyFramePacket] = []

        while true {
            switch state {
            case .awaitingHeader:
                guard buffer.count >= Self.headerSize else {
                    return frames
                }
                let headerData = buffer.prefix(Self.headerSize)
                let (pts, isConfig, isKey, size) = try parseHeader(headerData)
                buffer.removeFirst(Self.headerSize)
                state = .awaitingPayload(pts: pts, isConfig: isConfig, isKeyframe: isKey, size: Int(size))

            case .awaitingPayload(let pts, let isConfig, let isKey, let size):
                guard buffer.count >= size else {
                    return frames
                }
                let payload = buffer.prefix(size)
                buffer.removeFirst(size)
                frames.append(ScrcpyFramePacket(
                    ptsMicroseconds: pts,
                    isConfig: isConfig,
                    isKeyframe: isKey,
                    payload: Data(payload)
                ))
                state = .awaitingHeader
            }
        }
    }

    /// Parses the 12-byte scrcpy frame header.
    public func parseHeader(_ data: Data) throws -> (pts: UInt64, isConfig: Bool, isKeyframe: Bool, size: UInt32) {
        guard data.count >= Self.headerSize else {
            throw FrameDemuxError.invalidHeaderSize(expected: Self.headerSize, actual: data.count)
        }

        let ptsAndFlags = data.withUnsafeBytes { ptr -> UInt64 in
            ptr.load(as: UInt64.self).bigEndian
        }

        let isConfig = (ptsAndFlags & 0x8000_0000_0000_0000) != 0
        let isKeyframe = (ptsAndFlags & 0x4000_0000_0000_0000) != 0
        let pts = ptsAndFlags & 0x3FFF_FFFF_FFFF_FFFF

        let size = data.withUnsafeBytes { ptr -> UInt32 in
            ptr.load(fromByteOffset: 8, as: UInt32.self).bigEndian
        }

        if size > Self.maxPayloadSize {
            throw FrameDemuxError.payloadTooLarge(size: size, maxSize: Self.maxPayloadSize)
        }

        return (pts, isConfig, isKeyframe, size)
    }

    /// Serializes a frame header for testing or mock loopback transports.
    public static func serializeHeader(
        ptsMicroseconds: UInt64,
        isConfig: Bool,
        isKeyframe: Bool,
        payloadSize: UInt32
    ) -> Data {
        var header = Data(count: 12)
        var ptsAndFlags = ptsMicroseconds & 0x3FFF_FFFF_FFFF_FFFF
        if isConfig {
            ptsAndFlags |= 0x8000_0000_0000_0000
        }
        if isKeyframe {
            ptsAndFlags |= 0x4000_0000_0000_0000
        }

        var bePtsAndFlags = ptsAndFlags.bigEndian
        var beSize = payloadSize.bigEndian

        withUnsafeBytes(of: &bePtsAndFlags) { header.replaceSubrange(0..<8, with: $0) }
        withUnsafeBytes(of: &beSize) { header.replaceSubrange(8..<12, with: $0) }

        return header
    }
}

/// Output events emitted by the scrcpy v4.x socket stream demuxer.
public enum ScrcpyV4DemuxEvent: Sendable, Equatable {
    case deviceHandshake(deviceName: String, codec: VideoCodec)
    case sessionResize(width: Int, height: Int, isClientResized: Bool)
    case frame(ScrcpyFramePacket)
}

/// Deterministic scrcpy v4.x handshake + stream demuxer supporting session resize packets.
///
/// ### scrcpy v4.x Video Socket Layout (Big-Endian):
/// 1. `1B` dummy byte (`0x00`) on first socket
/// 2. `64B` UTF-8 NUL-padded device name
/// 3. `4B` codec ID (`0x68323635` = `"h265"`, `0x68323634` = `"h264"`)
/// 4. Stream of 12-byte headers:
///    - **Bit 63 = 1 (Session Packet, 12B total, no payload):**
///      `[0..4]` flags (`0x80000000` | `client_resized`), `[4..8]` width BE, `[8..12]` height BE
///    - **Bit 63 = 0 (Media Packet, 12B + N payload):**
///      `Bit 62` = `is_config`, `Bit 61` = `is_keyframe`, `Bits 0..60` = PTS µs, `[8..12]` size BE
public final class ScrcpyV4StreamDemuxer: @unchecked Sendable {
    private enum Phase {
        case awaitingDummyByte
        case awaitingDeviceName
        case awaitingCodecId(deviceName: String)
        case awaitingHeader
        case awaitingPayload(pts: UInt64, isConfig: Bool, isKeyframe: Bool, size: Int)
    }

    public static let maxPayloadSize: UInt32 = 32 * 1024 * 1024

    private var phase: Phase
    private var buffer = Data()

    public init(expectDummyByte: Bool = true) {
        self.phase = expectDummyByte ? .awaitingDummyByte : .awaitingDeviceName
    }

    public func feed(data: Data) throws -> [ScrcpyV4DemuxEvent] {
        buffer.append(data)
        var events: [ScrcpyV4DemuxEvent] = []

        while true {
            switch phase {
            case .awaitingDummyByte:
                guard buffer.count >= 1 else { return events }
                buffer.removeFirst(1)
                phase = .awaitingDeviceName

            case .awaitingDeviceName:
                guard buffer.count >= 64 else { return events }
                let rawName = buffer.prefix(64)
                buffer.removeFirst(64)
                let nulIndex = rawName.firstIndex(of: 0) ?? rawName.endIndex
                let deviceName = String(data: rawName[..<nulIndex], encoding: .utf8) ?? "Android Device"
                phase = .awaitingCodecId(deviceName: deviceName)

            case .awaitingCodecId(let deviceName):
                guard buffer.count >= 4 else { return events }
                let codecBytes = [UInt8](buffer.prefix(4))
                buffer.removeFirst(4)
                let codecId = (UInt32(codecBytes[0]) << 24)
                    | (UInt32(codecBytes[1]) << 16)
                    | (UInt32(codecBytes[2]) << 8)
                    | UInt32(codecBytes[3])
                let codec: VideoCodec
                switch codecId {
                case 0x6832_3635: codec = .h265
                case 0x6832_3634: codec = .h264
                case 0x0061_7631: codec = .av1
                default: codec = .h264
                }
                events.append(.deviceHandshake(deviceName: deviceName, codec: codec))
                phase = .awaitingHeader

            case .awaitingHeader:
                guard buffer.count >= 12 else { return events }
                let hdr = [UInt8](buffer.prefix(12))
                buffer.removeFirst(12)

                let isSession = (hdr[0] & 0x80) != 0
                if isSession {
                    let isClientResized = (hdr[3] & 0x01) != 0
                    let width = Int((UInt32(hdr[4]) << 24) | (UInt32(hdr[5]) << 16) | (UInt32(hdr[6]) << 8) | UInt32(hdr[7]))
                    let height = Int((UInt32(hdr[8]) << 24) | (UInt32(hdr[9]) << 16) | (UInt32(hdr[10]) << 8) | UInt32(hdr[11]))
                    events.append(.sessionResize(width: width, height: height, isClientResized: isClientResized))
                    continue
                }

                let ptsAndFlags = (UInt64(hdr[0]) << 56)
                    | (UInt64(hdr[1]) << 48)
                    | (UInt64(hdr[2]) << 40)
                    | (UInt64(hdr[3]) << 32)
                    | (UInt64(hdr[4]) << 24)
                    | (UInt64(hdr[5]) << 16)
                    | (UInt64(hdr[6]) << 8)
                    | UInt64(hdr[7])
                let isConfig = (ptsAndFlags & 0x4000_0000_0000_0000) != 0
                let isKeyframe = (ptsAndFlags & 0x2000_0000_0000_0000) != 0
                let pts = ptsAndFlags & 0x1FFF_FFFF_FFFF_FFFF
                let payloadSize = (UInt32(hdr[8]) << 24)
                    | (UInt32(hdr[9]) << 16)
                    | (UInt32(hdr[10]) << 8)
                    | UInt32(hdr[11])

                if payloadSize > Self.maxPayloadSize {
                    throw FrameDemuxError.payloadTooLarge(size: payloadSize, maxSize: Self.maxPayloadSize)
                }
                phase = .awaitingPayload(pts: pts, isConfig: isConfig, isKeyframe: isKeyframe, size: Int(payloadSize))

            case .awaitingPayload(let pts, let isConfig, let isKeyframe, let size):
                guard buffer.count >= size else { return events }
                let payload = Data(buffer.prefix(size))
                buffer.removeFirst(size)
                events.append(.frame(ScrcpyFramePacket(
                    ptsMicroseconds: pts,
                    isConfig: isConfig,
                    isKeyframe: isKeyframe,
                    payload: payload
                )))
                phase = .awaitingHeader
            }
        }
    }
}
