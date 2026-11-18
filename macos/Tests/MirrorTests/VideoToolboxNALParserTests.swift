import Testing
import Foundation
@testable import MirrorRenderer

@Suite("VideoToolbox and NAL Parser Tests")
struct VideoToolboxNALParserTests {
    let parser = NALParser()

    @Test("Splits Annex B byte stream with 3-byte and 4-byte start codes")
    func testSplitNALUnits() {
        var stream = Data()
        // 4-byte start code: 00 00 00 01 + [0x67, 0x42, 0xE0] (SPS)
        stream.append(contentsOf: [0x00, 0x00, 0x00, 0x01, 0x67, 0x42, 0xE0])
        // 3-byte start code: 00 00 01 + [0x68, 0xCE, 0x38] (PPS)
        stream.append(contentsOf: [0x00, 0x00, 0x01, 0x68, 0xCE, 0x38])
        // 4-byte start code: 00 00 00 01 + [0x65, 0x88, 0x80] (IDR)
        stream.append(contentsOf: [0x00, 0x00, 0x00, 0x01, 0x65, 0x88, 0x80])

        let units = parser.splitNALUnits(from: stream)
        #expect(units.count == 3)
        #expect(units[0] == Data([0x67, 0x42, 0xE0]))
        #expect(units[1] == Data([0x68, 0xCE, 0x38]))
        #expect(units[2] == Data([0x65, 0x88, 0x80]))
    }

    @Test("Classifies H.264 NAL unit types correctly")
    func testClassifyH264NALUnits() {
        // SPS: byte0 = 0x67 -> nal_type = 7
        let spsUnit = parser.parseH264NALUnit(Data([0x67, 0x42, 0x00, 0x1E]))
        #expect(spsUnit?.type == 7)
        #expect(spsUnit?.isParameterSet == true)
        #expect(spsUnit?.isKeyframe == false)

        // PPS: byte0 = 0x68 -> nal_type = 8
        let ppsUnit = parser.parseH264NALUnit(Data([0x68, 0xCE, 0x38, 0x80]))
        #expect(ppsUnit?.type == 8)
        #expect(ppsUnit?.isParameterSet == true)
        #expect(ppsUnit?.isKeyframe == false)

        // IDR: byte0 = 0x65 -> nal_type = 5
        let idrUnit = parser.parseH264NALUnit(Data([0x65, 0x88, 0x80, 0x40]))
        #expect(idrUnit?.type == 5)
        #expect(idrUnit?.isParameterSet == false)
        #expect(idrUnit?.isKeyframe == true)

        // Non-IDR: byte0 = 0x41 -> nal_type = 1
        let nonIdr = parser.parseH264NALUnit(Data([0x41, 0x9A, 0x12]))
        #expect(nonIdr?.type == 1)
        #expect(nonIdr?.isParameterSet == false)
        #expect(nonIdr?.isKeyframe == false)
    }

    @Test("Classifies H.265 (HEVC) NAL unit types correctly")
    func testClassifyHEVCNALUnits() {
        // VPS: type = 32 -> byte0 = (32 << 1) = 64 (0x40)
        let vps = parser.parseHEVCNALUnit(Data([0x40, 0x01, 0x0C, 0x01]))
        #expect(vps?.type == 32)
        #expect(vps?.isParameterSet == true)
        #expect(vps?.isKeyframe == false)

        // SPS: type = 33 -> byte0 = (33 << 1) = 66 (0x42)
        let sps = parser.parseHEVCNALUnit(Data([0x42, 0x01, 0x01, 0x01]))
        #expect(sps?.type == 33)
        #expect(sps?.isParameterSet == true)
        #expect(sps?.isKeyframe == false)

        // PPS: type = 34 -> byte0 = (34 << 1) = 68 (0x44)
        let pps = parser.parseHEVCNALUnit(Data([0x44, 0x01, 0xC0, 0xF3]))
        #expect(pps?.type == 34)
        #expect(pps?.isParameterSet == true)
        #expect(pps?.isKeyframe == false)

        // IDR_W_RADL: type = 19 -> byte0 = (19 << 1) = 38 (0x26)
        let idr = parser.parseHEVCNALUnit(Data([0x26, 0x01, 0xAF]))
        #expect(idr?.type == 19)
        #expect(idr?.isParameterSet == false)
        #expect(idr?.isKeyframe == true)

        // TRAIL_R: type = 1 -> byte0 = (1 << 1) = 2 (0x02)
        let trail = parser.parseHEVCNALUnit(Data([0x02, 0x01, 0xD0]))
        #expect(trail?.type == 1)
        #expect(trail?.isParameterSet == false)
        #expect(trail?.isKeyframe == false)
    }

    @Test("scrcpy 12-byte header serialization, parsing, and stream feeder")
    func testScrcpyHeaderAndDemuxFeeder() throws {
        let pts: UInt64 = 1_500_000 // 1.5 seconds in microseconds
        let payload = Data([0x26, 0x01, 0xAA, 0xBB, 0xCC, 0xDD])
        let headerData = FrameDemuxStateMachine.serializeHeader(
            ptsMicroseconds: pts,
            isConfig: false,
            isKeyframe: true,
            payloadSize: UInt32(payload.count)
        )

        let machine = FrameDemuxStateMachine()
        let parsed = try machine.parseHeader(headerData)
        #expect(parsed.pts == pts)
        #expect(parsed.isConfig == false)
        #expect(parsed.isKeyframe == true)
        #expect(parsed.size == UInt32(payload.count))

        // Feed header + payload through stream state machine in two partial chunks
        var fullPacket = Data()
        fullPacket.append(headerData)
        fullPacket.append(payload)

        // Feed first 8 bytes
        let frames1 = try machine.feed(data: fullPacket.prefix(8))
        #expect(frames1.isEmpty)

        // Feed remaining bytes
        let frames2 = try machine.feed(data: fullPacket.suffix(from: 8))
        #expect(frames2.count == 1)
        #expect(frames2[0].ptsMicroseconds == pts)
        #expect(frames2[0].isKeyframe == true)
        #expect(frames2[0].payload == payload)
    }
}
