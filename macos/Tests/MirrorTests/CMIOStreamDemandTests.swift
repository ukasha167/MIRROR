import Testing
import Foundation
@testable import MirrorWebcamExtension

final class MockDemandDelegate: CameraDemandDelegate, @unchecked Sendable {
    var startCallCount = 0
    var stopCallCount = 0
    var lastStartTimestamp: Date?
    var lastStopTimestamp: Date?

    func cameraDemandDidStart() {
        startCallCount += 1
        lastStartTimestamp = Date()
    }

    func cameraDemandDidStop() {
        stopCallCount += 1
        lastStopTimestamp = Date()
    }
}

@Suite("CMIO Camera Stream Demand Lifecycle Tests")
struct CMIOStreamDemandTests {
    @Test("Demand manager starts camera on first client and stops when empty")
    func testCameraDemandLifecycle() {
        let delegate = MockDemandDelegate()
        let manager = CameraDemandManager(delegate: delegate)

        #expect(manager.clientCount == 0)
        #expect(!manager.isStreaming)

        // 1. Zoom connects -> triggers start
        manager.clientDidConnect("us.zoom.xos")
        #expect(manager.clientCount == 1)
        #expect(manager.isStreaming)
        #expect(delegate.startCallCount == 1)
        #expect(delegate.stopCallCount == 0)

        // 2. FaceTime also connects -> streaming continues without duplicate start
        manager.clientDidConnect("com.apple.FaceTime")
        #expect(manager.clientCount == 2)
        #expect(manager.isStreaming)
        #expect(delegate.startCallCount == 1)
        #expect(delegate.stopCallCount == 0)

        // 3. Zoom disconnects -> FaceTime is still active, streaming stays on
        manager.clientDidDisconnect("us.zoom.xos")
        #expect(manager.clientCount == 1)
        #expect(manager.isStreaming)
        #expect(delegate.stopCallCount == 0)

        // 4. FaceTime disconnects -> last client, triggers stop
        let disconnectTime = Date()
        manager.clientDidDisconnect("com.apple.FaceTime")
        #expect(manager.clientCount == 0)
        #expect(!manager.isStreaming)
        #expect(delegate.stopCallCount == 1)

        // Verify stop was registered within 100ms
        if let stopTime = delegate.lastStopTimestamp {
            let elapsedMs = stopTime.timeIntervalSince(disconnectTime) * 1000.0
            #expect(elapsedMs < 100.0, "Expected stop signal within 100ms, elapsed was \(elapsedMs)ms")
        }
    }
}
