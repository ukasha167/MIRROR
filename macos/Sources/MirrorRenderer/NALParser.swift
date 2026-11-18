import Foundation
import CoreMedia
import VideoToolbox

/// Video codec format supported by the pipeline.
public enum VideoCodec: String, Sendable, Codable {
    case h265 = "h265"
    case h264 = "h264"
    case av1 = "av1"
}

/// Typed error for NAL unit and codec parameter parsing.
public enum NALParserError: Error, Sendable, CustomStringConvertible {
    case invalidStartCode(offset: Int)
    case truncatedBuffer(expected: Int, actual: Int)
    case missingParameterSets(codec: VideoCodec, reason: String)
    case formatDescriptionCreationFailed(status: OSStatus)
    case unsupportedCodec(VideoCodec)

    public var description: String {
        switch self {
        case .invalidStartCode(let offset):
            return "NALParserError: Invalid NAL start code at byte offset \(offset)"
        case .truncatedBuffer(let expected, let actual):
            return "NALParserError: Truncated buffer: expected at least \(expected) bytes, found \(actual)"
        case .missingParameterSets(let codec, let reason):
            return "NALParserError: Missing \(codec.rawValue) parameter sets: \(reason)"
        case .formatDescriptionCreationFailed(let status):
            return "NALParserError: CMVideoFormatDescription creation failed with OSStatus \(status)"
        case .unsupportedCodec(let codec):
            return "NALParserError: Codec \(codec.rawValue) is not supported for hardware decode on this chip"
        }
    }
}

/// Classified NAL unit with its raw payload and type.
public struct NALUnit: Sendable {
    public let type: UInt8
    public let data: Data
    public let isParameterSet: Bool
    public let isKeyframe: Bool

    public init(type: UInt8, data: Data, isParameterSet: Bool, isKeyframe: Bool) {
        self.type = type
        self.data = data
        self.isParameterSet = isParameterSet
        self.isKeyframe = isKeyframe
    }
}

/// Parser for H.264 and H.265 (HEVC) Network Abstraction Layer (NAL) units.
///
/// ### NAL Unit Header Byte Layout:
///
/// **H.264 NAL Header (1 byte):**
/// - `Bit 7`: forbidden_zero_bit (must be 0)
/// - `Bits 5..6`: nal_ref_idc (importance: 0=disposable, 1-3=reference)
/// - `Bits 0..4`: nal_unit_type (1=non-IDR slice, 5=IDR slice, 7=SPS, 8=PPS)
///
/// **H.265 (HEVC) NAL Header (2 bytes, Big Endian):**
/// - `Bit 15`: forbidden_zero_bit (must be 0)
/// - `Bits 9..14`: nal_unit_type ((byte0 >> 1) & 0x3F)
///   - 1 = TRAIL_R (non-keyframe slice)
///   - 19 = IDR_W_RADL, 20 = IDR_N_LP, 21 = CRA_NUT (keyframe slices)
///   - 32 = VPS (Video Parameter Set)
///   - 33 = SPS (Sequence Parameter Set)
///   - 34 = PPS (Picture Parameter Set)
/// - `Bits 3..8`: nuh_layer_id (typically 0)
/// - `Bits 0..2`: nuh_temporal_id_plus1
public final class NALParser: Sendable {
    public init() {}

    /// Splits an Annex B byte stream into individual NAL units.
    public func splitNALUnits(from data: Data) -> [Data] {
        var units: [Data] = []
        let bytes = [UInt8](data)
        let count = bytes.count
        guard count >= 4 else { return [] }

        struct NALRange {
            let prefixStart: Int
            let payloadStart: Int
        }

        var ranges: [NALRange] = []
        var i = 0
        while i < count - 2 {
            if bytes[i] == 0 && bytes[i + 1] == 0 {
                if bytes[i + 2] == 1 {
                    // 3-byte prefix (0x000001)
                    ranges.append(NALRange(prefixStart: i, payloadStart: i + 3))
                    i += 3
                    continue
                } else if i + 3 < count && bytes[i + 2] == 0 && bytes[i + 3] == 1 {
                    // 4-byte prefix (0x00000001)
                    ranges.append(NALRange(prefixStart: i, payloadStart: i + 4))
                    i += 4
                    continue
                }
            }
            i += 1
        }

        guard !ranges.isEmpty else { return [] }

        for idx in 0..<ranges.count {
            let payloadStart = ranges[idx].payloadStart
            let payloadEnd = (idx + 1 < ranges.count) ? ranges[idx + 1].prefixStart : count
            if payloadEnd > payloadStart {
                units.append(data.subdata(in: payloadStart..<payloadEnd))
            }
        }

        return units
    }

    /// Classifies an H.265 (HEVC) NAL unit.
    public func parseHEVCNALUnit(_ data: Data) -> NALUnit? {
        guard data.count >= 2 else { return nil }
        let byte0 = data[data.startIndex]
        let nalType = (byte0 >> 1) & 0x3F

        let isParamSet = (nalType == 32 || nalType == 33 || nalType == 34) // VPS, SPS, PPS
        let isKeyframe = (nalType >= 16 && nalType <= 21) // IDR or CRA

        return NALUnit(type: nalType, data: data, isParameterSet: isParamSet, isKeyframe: isKeyframe)
    }

    /// Classifies an H.264 NAL unit.
    public func parseH264NALUnit(_ data: Data) -> NALUnit? {
        guard data.count >= 1 else { return nil }
        let byte0 = data[data.startIndex]
        let nalType = byte0 & 0x1F

        let isParamSet = (nalType == 7 || nalType == 8) // SPS, PPS
        let isKeyframe = (nalType == 5) // IDR slice

        return NALUnit(type: nalType, data: data, isParameterSet: isParamSet, isKeyframe: isKeyframe)
    }

    /// Creates a CMVideoFormatDescription from HEVC parameter sets (VPS, SPS, PPS).
    public func createHEVCFormatDescription(
        vps: Data,
        sps: Data,
        pps: Data
    ) throws -> CMFormatDescription {
        var formatDesc: CMFormatDescription?
        let status = vps.withUnsafeBytes { vpsPtr in
            sps.withUnsafeBytes { spsPtr in
                pps.withUnsafeBytes { ppsPtr in
                    guard let vpsBase = vpsPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                          let spsBase = spsPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                          let ppsBase = ppsPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                        return OSStatus(-1)
                    }
                    let pointers = [vpsBase, spsBase, ppsBase]
                    let sizes = [vps.count, sps.count, pps.count]

                    return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: 3,
                        parameterSetPointers: pointers,
                        parameterSetSizes: sizes,
                        nalUnitHeaderLength: 4,
                        extensions: nil,
                        formatDescriptionOut: &formatDesc
                    )
                }
            }
        }

        guard status == noErr, let desc = formatDesc else {
            throw NALParserError.formatDescriptionCreationFailed(status: status)
        }

        return desc
    }

    /// Creates a CMVideoFormatDescription from H.264 parameter sets (SPS, PPS).
    public func createH264FormatDescription(
        sps: Data,
        pps: Data
    ) throws -> CMFormatDescription {
        var formatDesc: CMFormatDescription?
        let status = sps.withUnsafeBytes { spsPtr in
            pps.withUnsafeBytes { ppsPtr in
                guard let spsBase = spsPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let ppsBase = ppsPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return OSStatus(-1)
                }
                let pointers = [spsBase, ppsBase]
                let sizes = [sps.count, pps.count]

                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &formatDesc
                )
            }
        }

        guard status == noErr, let desc = formatDesc else {
            throw NALParserError.formatDescriptionCreationFailed(status: status)
        }

        return desc
    }

    /// Returns `true` when `data` begins with a 3-byte or 4-byte Annex B start code.
    public func isAnnexB(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let b0 = data[data.startIndex]
        let b1 = data[data.startIndex + 1]
        let b2 = data[data.startIndex + 2]
        let b3 = data[data.startIndex + 3]
        return (b0 == 0 && b1 == 0 && b2 == 1) || (b0 == 0 && b1 == 0 && b2 == 0 && b3 == 1)
    }

    /// Extracts H.265 VPS (32), SPS (33), and PPS (34) NAL payloads from an Annex B config buffer.
    public func extractHEVCParameterSets(from annexBData: Data) -> (vps: Data, sps: Data, pps: Data)? {
        var vps: Data?
        var sps: Data?
        var pps: Data?
        for unit in splitNALUnits(from: annexBData) {
            guard let parsed = parseHEVCNALUnit(unit) else { continue }
            switch parsed.type {
            case 32: vps = parsed.data
            case 33: sps = parsed.data
            case 34: pps = parsed.data
            default: break
            }
        }
        guard let v = vps, let s = sps, let p = pps else { return nil }
        return (v, s, p)
    }

    /// Extracts H.264 SPS (7) and PPS (8) NAL payloads from an Annex B config buffer.
    public func extractH264ParameterSets(from annexBData: Data) -> (sps: Data, pps: Data)? {
        var sps: Data?
        var pps: Data?
        for unit in splitNALUnits(from: annexBData) {
            guard let parsed = parseH264NALUnit(unit) else { continue }
            switch parsed.type {
            case 7: sps = parsed.data
            case 8: pps = parsed.data
            default: break
            }
        }
        guard let s = sps, let p = pps else { return nil }
        return (s, p)
    }

    /// Converts an Annex B byte stream into 4-byte big-endian length-prefixed AVCC/HVCC NAL units
    /// required by `CMVideoFormatDescription` (`nalUnitHeaderLength = 4`) and `VTDecompressionSession`.
    public func convertAnnexBToLengthPrefixed(
        _ annexBData: Data,
        codec: VideoCodec = .h265,
        includeParameterSets: Bool = false
    ) -> Data {
        let units = splitNALUnits(from: annexBData)
        guard !units.isEmpty else { return Data() }

        var out = Data()
        out.reserveCapacity(annexBData.count + units.count * 2)

        for unit in units {
            if !includeParameterSets {
                switch codec {
                case .h265:
                    if let parsed = parseHEVCNALUnit(unit), parsed.isParameterSet {
                        continue
                    }
                case .h264:
                    if let parsed = parseH264NALUnit(unit), parsed.isParameterSet {
                        continue
                    }
                case .av1:
                    break
                }
            }

            var lengthBE = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: &lengthBE) { out.append(contentsOf: $0) }
            out.append(unit)
        }
        return out
    }
}
