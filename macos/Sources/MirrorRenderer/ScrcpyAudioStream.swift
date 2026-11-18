import AVFoundation
import Foundation
import Network

/// Parses scrcpy's audio socket.
///
/// Layout (big-endian), with `send_stream_meta` and `send_frame_meta` on:
/// 1. `[0..4]` codec id. `0x00726177` ("raw") is 48 kHz stereo s16le PCM. `0` means the phone
///    could not capture audio and video goes on alone; `1` means a configuration error.
/// 2. Packets: `[0..8]` PTS in µs with flags (bit 63 session, bit 62 config, bit 61 key frame),
///    `[8..12]` payload size, then the payload.
public struct ScrcpyAudioDemuxer: Sendable {
    public enum Event: Equatable, Sendable {
        case codec(UInt32)
        /// The phone turned audio off for this session (code 0) or failed (code 1).
        case disabled(error: Bool)
        case pcm(Data)
    }

    public static let rawCodecID: UInt32 = 0x0072_6177
    /// Largest payload accepted. A raw packet is a few KiB; anything near this is a bad stream.
    public static let maxPayload = 1 << 20

    private var buffer = Data()
    private var codecRead = false

    public init() {}

    public mutating func feed(_ data: Data) throws -> [Event] {
        buffer.append(data)
        var events: [Event] = []
        if !codecRead {
            guard buffer.count >= 4 else { return events }
            let id = Self.u32(buffer, at: 0)
            buffer.removeFirst(4)
            codecRead = true
            if id <= 1 {
                buffer.removeAll()
                return [.disabled(error: id == 1)]
            }
            events.append(.codec(id))
        }
        while buffer.count >= 12 {
            let flags = buffer[buffer.startIndex]
            let size = Int(Self.u32(buffer, at: 8))
            guard size <= Self.maxPayload else {
                throw ScrcpyStreamError.networkFailure("Audio packet of \(size) bytes, limit \(Self.maxPayload)")
            }
            guard buffer.count >= 12 + size else { break }
            let payload = Data(buffer.dropFirst(12).prefix(size))
            buffer.removeFirst(12 + size)
            // Config packets (bit 62) carry codec setup; raw PCM has none worth playing.
            if flags & 0x40 == 0 { events.append(.pcm(payload)) }
        }
        return events
    }

    static func u32(_ data: Data, at offset: Int) -> UInt32 {
        let i = data.startIndex + offset
        return UInt32(data[i]) << 24 | UInt32(data[i + 1]) << 16 | UInt32(data[i + 2]) << 8 | UInt32(data[i + 3])
    }
}

/// Interleaved stereo s16 samples between the socket and the audio thread.
///
/// Wi-Fi delivers packets in bursts, so playback waits until `startFrames` are queued, and
/// drops the oldest samples once more than `maxFrames` wait (lag would otherwise grow for good
/// after each stall).
public final class PCMRingBuffer: @unchecked Sendable {
    public let startFrames: Int
    public let maxFrames: Int
    private let lock = NSLock()
    private var samples: [Int16] = []
    private var head = 0
    private var playing = false

    /// Defaults: start after 60 ms, keep at most 120 ms (48 kHz). The phone sends a burst at
    /// the start of a session; with a 200 ms cap, sound then stayed about 140 ms late.
    public init(startFrames: Int = 2_880, maxFrames: Int = 5_760) {
        self.startFrames = startFrames
        self.maxFrames = maxFrames
    }

    public var queuedFrames: Int { lock.withLock { (samples.count - head) / 2 } }

    public func write(_ pcm: Data) {
        lock.withLock {
            pcm.withUnsafeBytes { raw in
                samples.append(contentsOf: raw.bindMemory(to: Int16.self).map { Int16(littleEndian: $0) })
            }
            let excess = (samples.count - head) / 2 - maxFrames
            if excess > 0 { head += excess * 2 }
            if head > 48_000 {
                samples.removeFirst(head)
                head = 0
            }
        }
    }

    /// Fills `left` and `right` with `count` frames as floats; silence where none are queued.
    public func read(count: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        lock.withLock {
            let queued = (samples.count - head) / 2
            if !playing, queued >= startFrames { playing = true }
            let n = playing ? min(count, queued) : 0
            for i in 0..<n {
                left[i] = Float(samples[head + 2 * i]) / 32_768
                right[i] = Float(samples[head + 2 * i + 1]) / 32_768
            }
            head += 2 * n
            for i in n..<count {
                left[i] = 0
                right[i] = 0
            }
            // Ran dry: wait for a fresh cushion instead of clicking on every late packet.
            if n < count { playing = false }
        }
    }
}

/// Reads the audio socket and plays it on the Mac's default output.
final class ScrcpyAudioStream: @unchecked Sendable {
    private let connection: NWConnection
    private let ring = PCMRingBuffer()
    private var demuxer = ScrcpyAudioDemuxer()
    private let engine = AVAudioEngine()
    private var stopped = false
    private let lock = NSLock()
    var onLog: (@Sendable (String) -> Void)?

    init(connection: NWConnection) {
        self.connection = connection
    }

    func start(firstData: Data?) {
        if let firstData { handle(firstData) }
        readNext()
    }

    func stop() {
        lock.withLock { stopped = true }
        connection.cancel()
        engine.stop()
    }

    private var isStopped: Bool { lock.withLock { stopped } }

    private func readNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            guard let self, !self.isStopped else { return }
            if let data, !data.isEmpty { self.handle(data) }
            if done || error != nil { return }
            self.readNext()
        }
    }

    private func handle(_ data: Data) {
        do {
            for event in try demuxer.feed(data) {
                switch event {
                case .codec(let id) where id == ScrcpyAudioDemuxer.rawCodecID:
                    startEngine()
                case .codec(let id):
                    onLog?("Audio codec \(String(format: "0x%08x", id)) is not raw PCM; audio off")
                    stop()
                case .disabled(let error):
                    onLog?(error ? "Phone audio failed to start" : "Phone could not capture audio")
                case .pcm(let pcm):
                    ring.write(pcm)
                }
            }
        } catch {
            onLog?("Audio stream: \(error)")
            stop()
        }
    }

    private func startEngine() {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2) else { return }
        let ring = self.ring
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            ring.read(count: Int(frameCount), left: left, right: right)
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
        } catch {
            onLog?("Mac audio output failed: \(error)")
        }
    }
}
