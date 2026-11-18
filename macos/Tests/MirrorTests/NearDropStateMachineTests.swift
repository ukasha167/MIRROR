import Testing
import Foundation
import CryptoKit
@testable import NearDropReceiver

@Suite("NearDrop Receiver State Machine Tests")
struct NearDropStateMachineTests {
    @Test("UKEY2 handshake successfully derives session key and 4-digit PIN")
    func testUKEY2Handshake() throws {
        let session = UKEY2Session()

        // 1. Client generates ephemeral Curve25519 keypair and sends ClientInit
        let clientPriv = Curve25519.KeyAgreement.PrivateKey()
        let clientPub = clientPriv.publicKey.rawRepresentation
        var clientInitPayload = Data([UKEY2MessageType.clientInit.rawValue])
        clientInitPayload.append(clientPub)

        let serverInitResponse = try session.processClientInit(payload: clientInitPayload)
        #expect(serverInitResponse.count == 33) // 1 byte type + 32 bytes public key
        #expect(serverInitResponse[0] == UKEY2MessageType.serverInit.rawValue)

        // 2. Client sends ClientFinish
        let clientFinishPayload = Data([UKEY2MessageType.clientFinish.rawValue])
        let (pin, sessionKey) = try session.processClientFinish(payload: clientFinishPayload)

        #expect(pin.count == 4)
        #expect(Int(pin) != nil)
        #expect(sessionKey.count == 32)
        #expect(session.isAuthenticated)
    }

    @Test("UKEY2 rejects truncated client init payload")
    func testUKEY2TruncatedPayload() {
        let session = UKEY2Session()
        let truncated = Data([1, 2, 3, 4])
        #expect(throws: UKEY2Error.self) {
            try session.processClientInit(payload: truncated)
        }
    }

    @Test("Receiver state machine drives file transfer to completion")
    func testReceiverTransferLifecycle() {
        let receiver = ReceiverStateMachine()
        #expect(receiver.state == .waitingForConnection)

        let testFile = QuickShareFile(
            payloadId: 1001,
            filename: "photo.jpg",
            size: 2048,
            mimeType: "image/jpeg"
        )

        // Receive connection request with pin
        let status = receiver.handleConnectionRequest(
            sender: "Pixel 9",
            files: [testFile],
            pin: "1234"
        )
        #expect(status == .accept)
        #expect(receiver.state == .awaitingConsent(sender: "Pixel 9", files: [testFile], pin: "1234"))

        // Accept transfer
        receiver.acceptTransfer()
        #expect(receiver.state == .receiving(sender: "Pixel 9", files: [testFile], bytesReceived: 0, totalBytes: 2048))

        // Progress payload in chunks
        receiver.handlePayloadChunk(chunkSize: 1024)
        #expect(receiver.state == .receiving(sender: "Pixel 9", files: [testFile], bytesReceived: 1024, totalBytes: 2048))

        receiver.handlePayloadChunk(chunkSize: 1024)
        #expect(receiver.state == .completed(files: [testFile]))
    }

    @Test("Auto-accepts file transfer when device fingerprint is pinned")
    func testAutoAcceptPairedDevice() {
        let receiver = ReceiverStateMachine()
        receiver.autoAcceptPairedDevices = true
        receiver.pairedFingerprints.insert("pinned-fingerprint-abc")

        let file = QuickShareFile(payloadId: 1, filename: "doc.pdf", size: 500, mimeType: "application/pdf")
        let status = receiver.handleConnectionRequest(
            sender: "Trusted Phone",
            files: [file],
            pin: "9999",
            senderFingerprint: "pinned-fingerprint-abc"
        )

        #expect(status == .accept)
        // Auto-accepted directly into receiving state without awaiting consent
        #expect(receiver.state == .receiving(sender: "Trusted Phone", files: [file], bytesReceived: 0, totalBytes: 500))
    }
}
