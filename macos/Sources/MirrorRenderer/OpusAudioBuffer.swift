import Foundation

/// Audio packet carrying encoded Opus or raw PCM data.
public struct AudioFramePacket: Sendable {
    public let ptsMicroseconds: UInt64
    public let data: Data

    public init(ptsMicroseconds: UInt64, data: Data) {
        self.ptsMicroseconds = ptsMicroseconds
        self.data = data
    }
}

/// Ringbuffer for Opus audio frames received from scrcpy audio socket.
public actor OpusAudioBuffer {
    private var buffer: [AudioFramePacket] = []
    public let maxCapacity: Int
    private var droppedFramesCount: Int = 0

    public init(maxCapacity: Int = 100) {
        self.maxCapacity = maxCapacity
        self.buffer.reserveCapacity(maxCapacity)
    }

    /// Pushes a new audio packet into the ringbuffer.
    public func push(packet: AudioFramePacket) {
        if buffer.count >= maxCapacity {
            buffer.removeFirst()
            droppedFramesCount += 1
        }
        buffer.append(packet)
    }

    /// Pops the oldest audio packet from the ringbuffer.
    public func pop() -> AudioFramePacket? {
        guard !buffer.isEmpty else { return nil }
        return buffer.removeFirst()
    }

    /// Clears all frames from the ringbuffer.
    public func clear() {
        buffer.removeAll(keepingCapacity: true)
    }

    public var count: Int {
        buffer.count
    }

    public var droppedFrames: Int {
        droppedFramesCount
    }
}
