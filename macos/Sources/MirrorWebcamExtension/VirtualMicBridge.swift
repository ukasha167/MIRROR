import Foundation

/// CoreAudio virtual microphone bridge configuration (libASPL compatible).
public struct VirtualMicConfig: Sendable, Codable, Equatable {
    public let deviceName: String
    public let manufacturer: String
    public let sampleRate: Double
    public let channelCount: UInt32
    public let frameDurationMs: Double
    public let bufferCapacityFrames: UInt32

    public init(
        deviceName: String = "Android Continuity Mic",
        manufacturer: String = "Mirror Continuity",
        sampleRate: Double = 48000.0,
        channelCount: UInt32 = 2,
        frameDurationMs: Double = 20.0,
        bufferCapacityFrames: UInt32 = 48000 // 1 second ringbuffer
    ) {
        self.deviceName = deviceName
        self.manufacturer = manufacturer
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.frameDurationMs = frameDurationMs
        self.bufferCapacityFrames = bufferCapacityFrames
    }

    /// Number of audio frames per packet (e.g. 48000 * 0.02 = 960 frames).
    public var framesPerPacket: UInt32 {
        UInt32(sampleRate * (frameDurationMs / 1000.0))
    }

    /// Bytes per audio frame (32-bit float stereo = 8 bytes).
    public var bytesPerFrame: UInt32 {
        channelCount * UInt32(MemoryLayout<Float32>.size)
    }
}

/// Bridge manager interfacing between scrcpy Opus audio and CoreAudio libASPL driver.
public final class VirtualMicBridge: @unchecked Sendable {
    public let config: VirtualMicConfig
    private var isRunning: Bool = false
    private let lock = NSLock()

    public init(config: VirtualMicConfig = VirtualMicConfig()) {
        self.config = config
    }

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        isRunning = true
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        isRunning = false
    }

    public var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isRunning
    }
}
