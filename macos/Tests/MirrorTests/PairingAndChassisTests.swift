import Testing
import Foundation
import Network
@testable import MirrorCoreBridge
@testable import MirrorRenderer
@testable import MirrorApp

@Suite("Continuity Pairing, Scrcpy V4, Control Wire, and Chassis Tests")
struct PairingAndChassisTests {
    @Test("ContinuityPairingCodec round-trips escaped QR fields and normalizes PINs")
    func testQrRoundTripAndPinNormalization() throws {
        #expect(ContinuityPairingCodec.normalizePin("849-201") == "849201")
        #expect(ContinuityPairingCodec.formatPin("849201") == "849 201")

        let payload = ContinuityPairingPayload(
            serviceName: "_mirror-cont._tcp",
            passcode: "527491",
            deviceId: "mac-studio-01",
            deviceName: "Ukasha: Mac;Book, Air\\Studio",
            fingerprint: "deadbeef01234567",
            endpoints: [
                ContinuityEndpointCandidate(address: "192.168.1.25:53318", kind: .lan),
                ContinuityEndpointCandidate(address: "127.0.0.1:53318", kind: .usb)
            ],
            expiresAt: 4_000_000_000
        )

        let qrString = ContinuityPairingCodec.encodeQR(payload)
        let decoded = try ContinuityPairingCodec.decodeQR(qrString, validateExpiry: true, nowEpochSeconds: 1_700_000_000)

        #expect(decoded.serviceName == payload.serviceName)
        #expect(decoded.passcode == "527491")
        #expect(decoded.deviceId == "mac-studio-01")
        #expect(decoded.deviceName == "Ukasha: Mac;Book, Air\\Studio")
        #expect(decoded.fingerprint == "deadbeef01234567")
        #expect(decoded.endpoints.count == 2)
        #expect(decoded.endpoints[0].host == "192.168.1.25")
        #expect(decoded.endpoints[0].port == 53318)
    }

    @Test("ContinuityPairingCodec rejects expired QR codes and short PINs")
    func testQrRejectsInvalidAndExpired() {
        let expiredQr = "WIFI:T:ADB;S:_mirror-cont._tcp;P:123456;ID:m1;NAME:Mac;FP:abcd;EP:;EXP:100;;"
        #expect(throws: ContinuityPairingError.self) {
            _ = try ContinuityPairingCodec.decodeQR(expiredQr, validateExpiry: true, nowEpochSeconds: 200)
        }

        let badPinQr = "WIFI:T:ADB;S:_mirror-cont._tcp;P:123;ID:m1;NAME:Mac;FP:abcd;EP:;EXP:9999999999;;"
        #expect(throws: ContinuityPairingError.self) {
            _ = try ContinuityPairingCodec.decodeQR(badPinQr, validateExpiry: false)
        }
    }

    @Test("ScrcpyV4StreamDemuxer parses handshake, session resize, config, and keyframes")
    func testScrcpyV4Demuxer() throws {
        var stream = Data()
        stream.append(0x00) // dummy byte

        // 64B device name
        var nameBytes = Data("Galaxy S23 Ultra".utf8)
        nameBytes.append(Data(repeating: 0, count: 64 - nameBytes.count))
        stream.append(nameBytes)

        // 4B codec ID: "h265"
        stream.append(Data("h265".utf8))

        // Session resize packet (Bit 63 set, width=1080, height=2340)
        stream.append(contentsOf: [0x80, 0x00, 0x00, 0x01])
        stream.append(contentsOf: [0x00, 0x00, 0x04, 0x38]) // 1080
        stream.append(contentsOf: [0x00, 0x00, 0x09, 0x24]) // 2340

        // Config frame (Bit 62 set, size=4)
        stream.append(contentsOf: [0x40, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        stream.append(contentsOf: [0x00, 0x00, 0x00, 0x04])
        stream.append(contentsOf: [0x00, 0x00, 0x00, 0x01])

        // Keyframe (Bit 61 set, pts=1234, size=3)
        stream.append(contentsOf: [0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0xD2])
        stream.append(contentsOf: [0x00, 0x00, 0x00, 0x03])
        stream.append(contentsOf: [0xAA, 0xBB, 0xCC])

        let demuxer = ScrcpyV4StreamDemuxer(expectDummyByte: true)
        let events = try demuxer.feed(data: stream)

        #expect(events.count == 4)
        #expect(events[0] == .deviceHandshake(deviceName: "Galaxy S23 Ultra", codec: .h265))
        #expect(events[1] == .sessionResize(width: 1080, height: 2340, isClientResized: true))
        guard case .frame(let cfg) = events[2] else {
            Issue.record("Expected config packet")
            return
        }
        #expect(cfg.isConfig == true)
        guard case .frame(let key) = events[3] else {
            Issue.record("Expected keyframe packet")
            return
        }
        #expect(key.isKeyframe == true)
        #expect(key.ptsMicroseconds == 1234)
        #expect(key.payload == Data([0xAA, 0xBB, 0xCC]))
    }

    @Test("NALParser converts Annex B HEVC stream to 4-byte length-prefixed slices")
    func testAnnexBToLengthPrefixed() {
        let parser = NALParser()
        var annexB = Data()
        annexB.append(contentsOf: [0x00, 0x00, 0x00, 0x01, 0x40, 0x01, 0x0C]) // HEVC VPS (32)
        annexB.append(contentsOf: [0x00, 0x00, 0x00, 0x01, 0x42, 0x01, 0x01]) // HEVC SPS (33)
        annexB.append(contentsOf: [0x00, 0x00, 0x01, 0x44, 0x01, 0xC0])       // HEVC PPS (34)
        annexB.append(contentsOf: [0x00, 0x00, 0x00, 0x01, 0x26, 0x01, 0xAF, 0x55]) // HEVC IDR (19)

        let params = parser.extractHEVCParameterSets(from: annexB)
        #expect(params?.vps == Data([0x40, 0x01, 0x0C]))
        #expect(params?.sps == Data([0x42, 0x01, 0x01]))
        #expect(params?.pps == Data([0x44, 0x01, 0xC0]))

        let sliceOnly = parser.convertAnnexBToLengthPrefixed(annexB, codec: .h265, includeParameterSets: false)
        // Expected: [00, 00, 00, 04, 0x26, 0x01, 0xAF, 0x55]
        #expect(sliceOnly == Data([0x00, 0x00, 0x00, 0x04, 0x26, 0x01, 0xAF, 0x55]))
    }

    @Test("ScrcpyControlEncoder produces exact big-endian binary control frames")
    func testControlEncoderWireLayouts() {
        let touch = ScrcpyControlEncoder.injectTouch(
            action: .down, x: 540, y: 1200, screenWidth: 1080, screenHeight: 2400, pressure: 1.0
        )
        #expect(touch.count == 32)
        #expect(touch[0] == 2)
        #expect(touch[1] == 0)
        #expect(Array(touch[2..<10]) == Array(repeating: 0xFF, count: 8)) // pointerId = -1
        #expect(Array(touch[22..<24]) == [0xFF, 0xFF]) // pressure 1.0

        let scroll = ScrcpyControlEncoder.injectScroll(
            x: 100, y: 200, screenWidth: 1080, screenHeight: 2400, horizontalScroll: 0, verticalScroll: -16.0
        )
        #expect(scroll.count == 21)
        #expect(scroll[0] == 3)
        #expect(Array(scroll[15..<17]) == [0x80, 0x00]) // -16 -> -32768 BE

        let startApp = ScrcpyControlEncoder.startApp(packageName: "com.whatsapp")
        #expect(startApp[0] == 16)
        #expect(startApp[1] == 12) // 1-byte length prefix per scrcpy 4.1
        #expect(String(data: startApp.dropFirst(2), encoding: .utf8) == "com.whatsapp")
    }

    @Test("PhoneChassisMetrics preserves recording aspect ratio across portrait, foldable, and landscape")
    func testChassisAspectFitting() {
        let container = CGSize(width: 540, height: 680)
        let samples: [CGSize] = [
            CGSize(width: 1080, height: 2400),
            CGSize(width: 1440, height: 3088),
            CGSize(width: 2400, height: 1080),
            CGSize(width: 1768, height: 2208)
        ]

        for video in samples {
            let m = PhoneChassisMetrics.fit(videoSize: video, in: container)
            let expectedRatio = video.width / video.height
            let actualRatio = m.screenSize.width / m.screenSize.height
            #expect(abs(actualRatio - expectedRatio) < 0.02)
            #expect(m.chassisSize.width <= container.width)
            #expect(m.chassisSize.height <= container.height)
            #expect(m.outerCornerRadius == m.innerCornerRadius + m.bezel)
            #expect(m.isLandscape == (video.width > video.height))
        }
    }

    @Test("ContinuityHostServer gates connected status on mutual app handshake and pairing code")
    func testHostServerMutualHandshakeGating() {
        let suiteName = "dev.mirror.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = PairedPeerStore(defaults: defaults)
        let server = ContinuityHostServer(peerStore: store)

        final class EmittedBox: @unchecked Sendable {
            let lock = NSLock()
            var items: [ContinuityWireMessage] = []
            func append(_ m: ContinuityWireMessage) { lock.lock(); items.append(m); lock.unlock() }
            func popFirst() -> ContinuityWireMessage? { lock.lock(); defer { lock.unlock() }; return items.isEmpty ? nil : items.removeFirst() }
        }
        let emitted = EmittedBox()
        let testQueue = DispatchQueue(label: "dev.mirror.test.loopback")
        let session = ContinuityTcpSession(isUsbTransport: true, queue: testQueue) { msg in
            emitted.append(msg)
        }

        func sendAndPopResponse(_ msg: ContinuityWireMessage) -> ContinuityWireMessage? {
            server.dispatchTestMessage(msg, session: session)
            return emitted.popFirst()
        }

        // 1. Untrusted hello (e.g. cable plugged / app probing without token) must NOT mark connected
        let helloResp = sendAndPopResponse(ContinuityWireMessage(
            type: .hello, deviceId: "pixel-test-1", deviceName: "Pixel 9", deviceModel: "Pixel 9 Pro", role: "android"
        ))
        #expect(helloResp?.type == .helloAck)
        #expect(helloResp?.accepted == false)
        #expect(server.snapshotConnectedPeer() == nil)

        // 2. Wrong pair code must be rejected and remain disconnected
        let badPairResp = sendAndPopResponse(ContinuityWireMessage(
            type: .pairRequest, deviceId: "pixel-test-1", deviceName: "Pixel 9", deviceModel: "Pixel 9 Pro", role: "android", code: "000000"
        ))
        #expect(badPairResp?.type == .pairResponse)
        #expect(badPairResp?.accepted == false)
        #expect(server.snapshotConnectedPeer() == nil)

        // 3. Valid 6-digit Mac code promotes peer to verified connected state with persistent token
        let validCode = server.currentPairingPin()
        let okPairResp = sendAndPopResponse(ContinuityWireMessage(
            type: .pairRequest, deviceId: "pixel-test-1", deviceName: "Pixel 9", deviceModel: "Pixel 9 Pro", role: "android", code: validCode
        ))
        #expect(okPairResp?.type == .pairResponse)
        #expect(okPairResp?.accepted == true)
        let token = okPairResp?.pairToken ?? ""
        #expect(!token.isEmpty)
        #expect(server.snapshotConnectedPeer()?.id == "pixel-test-1")

        // 4. Bye packet tears down verified connection immediately
        server.dispatchTestMessage(
            ContinuityWireMessage(type: .bye, deviceId: "pixel-test-1", deviceName: "Pixel 9", deviceModel: "Pixel 9 Pro", role: "android"),
            session: session
        )
        #expect(server.snapshotConnectedPeer() == nil)

        // 5. Reconnecting with saved pairToken authenticates automatically without re-entering PIN
        let reconnectAck = sendAndPopResponse(ContinuityWireMessage(
            type: .hello, deviceId: "pixel-test-1", deviceName: "Pixel 9", deviceModel: "Pixel 9 Pro", role: "android", pairToken: token
        ))
        #expect(reconnectAck?.type == .helloAck)
        #expect(reconnectAck?.accepted == true)
        #expect(server.snapshotConnectedPeer()?.id == "pixel-test-1")
    }

    @Test("ContinuityHostServer QR payload includes USB loopback endpoint only while USB device is attached")
    func testHostServerQrIncludesUsbEndpoint() throws {
        let suiteName = "dev.mirror.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let server = ContinuityHostServer(peerStore: PairedPeerStore(defaults: defaults))
        server.setLocalAdbSerial("28161FDH300LZD")
        let qrWithUsb = server.currentQrPayloadString()
        let decodedUsb = try ContinuityPairingCodec.decodeQR(qrWithUsb, validateExpiry: false)
        #expect(decodedUsb.endpoints.contains { $0.kind == .usb && $0.host == "127.0.0.1" })

        server.setLocalAdbSerial(nil)
        let qrWithoutUsb = server.currentQrPayloadString()
        let decodedNoUsb = try ContinuityPairingCodec.decodeQR(qrWithoutUsb, validateExpiry: false)
        #expect(!decodedNoUsb.endpoints.contains { $0.kind == .usb })
    }
}
