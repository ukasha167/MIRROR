package dev.mirror.continuity

import dev.mirror.continuity.network.ContinuityConnectionPolicy
import dev.mirror.continuity.network.ContinuityProtocolRouter
import dev.mirror.continuity.network.ContinuityUiConnectionStatus
import dev.mirror.continuity.network.ContinuityWireMessage
import dev.mirror.continuity.network.DiscoveredMacPeer
import dev.mirror.continuity.pairing.ContinuityEndpoint
import dev.mirror.continuity.pairing.ContinuityPairingCodec
import dev.mirror.continuity.pairing.ContinuityPairingException
import dev.mirror.continuity.pairing.ContinuityPairingPayload
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class ContinuityPairingCodecTest {

    @Test
    fun qrEncodeDecodeRoundTripsEscapedFields() {
        val payload = ContinuityPairingPayload(
            serviceName = "_mirror-cont._tcp",
            passcode = "482910",
            deviceId = "mac-01",
            deviceName = "Ukasha's Mac: Book;Pro, 16\\M",
            fingerprint = "abcdef123456",
            endpoints = listOf(
                ContinuityEndpoint(address = "192.168.1.50:53318", kind = "lan"),
                ContinuityEndpoint(address = "127.0.0.1:53318", kind = "usb")
            ),
            expiresAt = 4_000_000_000L
        )

        val qr = ContinuityPairingCodec.encodeQr(payload)
        val decoded = ContinuityPairingCodec.decodeQr(qr, validateExpiry = true, nowEpochSeconds = 1_700_000_000L)

        assertEquals(payload.serviceName, decoded.serviceName)
        assertEquals("482910", decoded.passcode)
        assertEquals("mac-01", decoded.deviceId)
        assertEquals("Ukasha's Mac: Book;Pro, 16\\M", decoded.deviceName)
        assertEquals(2, decoded.endpoints.size)
        assertEquals("192.168.1.50", decoded.endpoints[0].host)
        assertEquals(53318, decoded.endpoints[0].port)
    }

    @Test
    fun expiredQrThrowsPairingException() {
        val expiredQr = "WIFI:T:ADB;S:_mirror-cont._tcp;P:123456;ID:m1;NAME:Mac;FP:fp1;EP:10.0.0.2\\:53318@lan;EXP:500;;"
        assertThrows(ContinuityPairingException::class.java) {
            ContinuityPairingCodec.decodeQr(expiredQr, validateExpiry = true, nowEpochSeconds = 1_000L)
        }
    }

    @Test
    fun pinNormalizationAndFormattingWorks() {
        assertEquals("849201", ContinuityPairingCodec.normalizePin("849-201"))
        assertEquals("849201", ContinuityPairingCodec.normalizePin("849 201999"))
        assertEquals("849 201", ContinuityPairingCodec.formatPin("849201"))
    }

    @Test
    fun wireMessageJsonLineRoundTripsCleanly() {
        val msg = ContinuityWireMessage(
            type = "pair_request",
            deviceId = "pixel-123",
            deviceName = "Pixel 9 \"Pro\"\\Test",
            deviceModel = "Pixel 9 Pro",
            role = "android",
            code = "901234",
            listeningPort = 53319,
            timestampMs = 1_700_000_000_000L
        )
        val jsonLine = msg.toJsonLine()
        val parsed = ContinuityWireMessage.fromJsonLine(jsonLine)
        assertNotNull(parsed)
        assertEquals("pair_request", parsed?.type)
        assertEquals("pixel-123", parsed?.deviceId)
        assertEquals("Pixel 9 \"Pro\"\\Test", parsed?.deviceName)
        assertEquals("901234", parsed?.code)
        assertEquals(53319, parsed?.listeningPort)
    }

    @Test
    fun usbCableAloneNeverMarksConnectionAsConnected() {
        val usbOnly = ContinuityConnectionPolicy.evaluateMutualConnection(
            isHandshakeVerified = false,
            verifiedMacName = null,
            isUsbCableAttached = true
        )
        assertTrue(usbOnly is ContinuityUiConnectionStatus.UsbWaitingForMacApp)

        val unplugged = ContinuityConnectionPolicy.evaluateMutualConnection(
            isHandshakeVerified = false,
            verifiedMacName = "Ukasha's MacBook Pro",
            isUsbCableAttached = false
        )
        assertTrue(unplugged is ContinuityUiConnectionStatus.Disconnected)

        val verified = ContinuityConnectionPolicy.evaluateMutualConnection(
            isHandshakeVerified = true,
            verifiedMacName = "Ukasha's MacBook Pro",
            isUsbCableAttached = true
        )
        assertEquals(ContinuityUiConnectionStatus.Connected("Ukasha's MacBook Pro"), verified)
    }

    @Test
    fun pairCandidatesPrioritizeUsbAndIncludeLoopbackFallback() {
        val wifiMac = DiscoveredMacPeer("m1", "Mac Studio", "192.168.18.26", 53318, viaUsb = false)
        val usbAttached = ContinuityProtocolRouter.buildPairCandidates(
            manualAddress = null,
            selectedMac = wifiMac,
            discoveredMacs = listOf(wifiMac),
            isUsbAttached = true,
            defaultPort = 53318
        )
        assertEquals(Triple("127.0.0.1", 53318, true), usbAttached.first())
        assertEquals(Triple("192.168.18.26", 53318, false), usbAttached[1])

        val manualAndFallback = ContinuityProtocolRouter.buildPairCandidates(
            manualAddress = "10.0.0.5:53318",
            selectedMac = null,
            discoveredMacs = emptyList(),
            isUsbAttached = false,
            defaultPort = 53318
        )
        assertEquals(
            listOf(
                Triple("10.0.0.5", 53318, false),
                Triple("127.0.0.1", 53318, true)
            ),
            manualAndFallback
        )

        val qrCandidates = ContinuityProtocolRouter.buildQrCandidates(
            endpoints = listOf(
                ContinuityEndpoint("192.168.18.26:53318", "lan"),
                ContinuityEndpoint("127.0.0.1:53318", "usb")
            ),
            isUsbAttached = true,
            defaultPort = 53318
        )
        assertEquals(
            listOf(
                Triple("127.0.0.1", 53318, true),
                Triple("192.168.18.26", 53318, false)
            ),
            qrCandidates
        )
    }

    @Test
    fun mergeDiscoveredMacsDeduplicatesAndPrioritizesUsbPeers() {
        val usbMac = DiscoveredMacPeer("m1", "Ukasha\u2019s MacBook Air", "127.0.0.1", 53318, viaUsb = true)
        val lanMac = DiscoveredMacPeer("m1", "Ukasha\u2019s MacBook Air", "192.168.18.26", 53318, viaUsb = false)
        val secondLan = DiscoveredMacPeer("m2", "Studio", "192.168.18.40", 53318, viaUsb = false)

        val merged = ContinuityProtocolRouter.mergeDiscoveredMacs(listOf(usbMac), listOf(lanMac, secondLan))
        assertEquals(2, merged.size)
        assertTrue(merged[0].viaUsb)
        assertEquals("127.0.0.1", merged[0].host)
        assertEquals("m2", merged[1].id)
    }

    @Test
    fun parsesSwiftEncodedUnicodeJsonWireMessage() {
        val swiftJson = "{\"accepted\":false,\"deviceId\":\"mac-air-1\",\"deviceModel\":\"Mac\",\"deviceName\":\"Ukasha\\u2019s MacBook Air\",\"listeningPort\":53318,\"reason\":\"Pairing required\",\"role\":\"mac\",\"timestampMs\":1794601000000,\"type\":\"hello_ack\"}"
        val parsed = ContinuityWireMessage.fromJsonLine(swiftJson)
        assertNotNull(parsed)
        assertEquals("hello_ack", parsed?.type)
        assertEquals("Ukasha\u2019s MacBook Air", parsed?.deviceName)
        assertEquals(false, parsed?.accepted)
        assertEquals(53318, parsed?.listeningPort)

        val rawUtf8Json = "{\"accepted\":true,\"deviceId\":\"mac-air-1\",\"deviceModel\":\"Mac\",\"deviceName\":\"Ukasha’s MacBook Air\",\"listeningPort\":53318,\"pairToken\":\"tok_abc\",\"role\":\"mac\",\"type\":\"pair_response\"}"
        val parsedUtf8 = ContinuityWireMessage.fromJsonLine(rawUtf8Json)
        assertEquals("Ukasha’s MacBook Air", parsedUtf8?.deviceName)
        assertEquals("tok_abc", parsedUtf8?.pairToken)
        assertEquals(true, parsedUtf8?.accepted)
    }
}
