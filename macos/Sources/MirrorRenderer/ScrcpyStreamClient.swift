import Foundation
import Network
import CoreMedia
import CoreVideo

/// Manages `scrcpy-server` lifecycle, ADB forwarding, H.265/H.264 stream demuxing, VideoToolbox decoding, and control injection.
public final class ScrcpyStreamClient: @unchecked Sendable {
    public enum StreamState: Equatable, Sendable {
        case idle
        case starting
        case streaming(width: Int, height: Int, codec: VideoCodec)
        case failed(String)
    }

    public static let serverProtocolVersion = "4.1"

    public var onPixelBuffer: (@Sendable (CVPixelBuffer, CMTime) -> Void)?
    public var onVideoDimensionsChanged: (@Sendable (CGSize) -> Void)?
    public var onStateChanged: (@Sendable (StreamState) -> Void)?
    public var onDeviceName: (@Sendable (String, VideoCodec) -> Void)?
    /// Raw server output (stdout and stderr), in chunks as they arrive.
    public var onServerLog: (@Sendable (String) -> Void)?

    private let ioQueue = DispatchQueue(label: "dev.mirror.scrcpy.stream", qos: .userInteractive)
    private let stateLock = NSLock()

    private var activeSessionID: UUID?
    private var serverProcess: Process?
    private var serverStderrBuffer = Data()
    private var videoConnection: NWConnection?
    private var controlConnection: NWConnection?
    private var demuxer: ScrcpyV4StreamDemuxer?
    private var decoder: VideoToolboxDecoder?
    private var negotiatedCodec: VideoCodec = .h265
    private var forwardedPort: UInt16?
    private var activeSerial: String?
    private var activeAdbPath: String?
    private var pendingStartApp: String?
    private var options = ServerOptions()

    /// Session settings beyond codec and size. `serverPath` must match `serverProtocolVersion`.
    public struct ServerOptions: Sendable, Equatable {
        public var serverPath: String?
        public var videoBitRate = 8_000_000
        /// Extra `key=value` server arguments, such as `new_display=1600x1000/200`.
        public var extraArguments: [String] = []
        public init(serverPath: String? = nil, videoBitRate: Int = 8_000_000, extraArguments: [String] = []) {
            self.serverPath = serverPath
            self.videoBitRate = videoBitRate
            self.extraArguments = extraArguments
        }
    }

    public init() {}

    deinit {
        stop()
    }

    /// Starts embedded mirroring against `serial` using `adbPath`. Tries `preferredCodec` first and falls back to H.264 if H.265 fails.
    public func start(
        serial: String,
        adbPath: String,
        preferredCodec: VideoCodec = .h265,
        maxSize: Int = 1920,
        maxFps: Int = 60,
        initialPackage: String? = nil,
        options: ServerOptions = ServerOptions()
    ) async throws {
        self.options = options
        do {
            try await startAttempt(serial: serial, adbPath: adbPath, codec: preferredCodec, maxSize: maxSize, maxFps: maxFps, initialPackage: initialPackage)
        } catch {
            guard preferredCodec == .h265 else {
                onStateChanged?(.failed(error.localizedDescription))
                throw error
            }
            try await startAttempt(serial: serial, adbPath: adbPath, codec: .h264, maxSize: maxSize, maxFps: maxFps, initialPackage: initialPackage)
        }
    }

    /// Sends raw scrcpy control message bytes (see `ScrcpyControlEncoder`).
    public func sendControl(_ data: Data) {
        ioQueue.async { [weak self] in
            guard let self, let controlConn = self.controlConnection else { return }
            controlConn.send(content: data, completion: .contentProcessed { _ in })
        }
    }

    /// Tears down video/control sockets, terminates the remote server process, and removes `adb forward`.
    public func stop() {
        let (proc, video, control, serial, adb, port) = stateLock.withLock {
            activeSessionID = nil
            let s = (serverProcess, videoConnection, controlConnection, activeSerial, activeAdbPath, forwardedPort)
            serverProcess = nil
            videoConnection = nil
            controlConnection = nil
            activeSerial = nil
            activeAdbPath = nil
            forwardedPort = nil
            demuxer = nil
            decoder?.invalidate()
            decoder = nil
            pendingStartApp = nil
            return s
        }

        video?.cancel()
        control?.cancel()
        if let proc, proc.isRunning { proc.terminate() }
        if let adb, let serial, let port {
            DispatchQueue.global(qos: .utility).async {
                _ = try? ScrcpyAdbTransport.runAdbSync(adbPath: adb, arguments: ["-s", serial, "forward", "--remove", "tcp:\(port)"])
            }
        }
        onStateChanged?(.idle)
    }

    private func startAttempt(
        serial: String,
        adbPath: String,
        codec: VideoCodec,
        maxSize: Int,
        maxFps: Int,
        initialPackage: String?
    ) async throws {
        stop()

        let sessionID = UUID()
        onStateChanged?(.starting)

        let serverPath = try options.serverPath ?? ScrcpyAdbTransport.resolveServerPath()
        try await ScrcpyAdbTransport.runAdbAsync(adbPath: adbPath, arguments: ["-s", serial, "push", serverPath, "/data/local/tmp/scrcpy-server.jar"])

        let localPort = try ScrcpyAdbTransport.allocateLoopbackPort()
        let scidHex = String(format: "%08x", UInt32.random(in: 1..<0x7FFF_FFFF))
        try await ScrcpyAdbTransport.runAdbAsync(
            adbPath: adbPath,
            arguments: ["-s", serial, "forward", "tcp:\(localPort)", "localabstract:scrcpy_\(scidHex)"]
        )

        let proc = buildServerProcess(adbPath: adbPath, serial: serial, scidHex: scidHex, codec: codec, maxSize: maxSize, maxFps: maxFps, sessionID: sessionID)
        stateLock.withLock {
            activeSessionID = sessionID
            activeSerial = serial
            activeAdbPath = adbPath
            forwardedPort = localPort
            serverProcess = proc
            serverStderrBuffer.removeAll(keepingCapacity: false)
            demuxer = ScrcpyV4StreamDemuxer(expectDummyByte: true)
            negotiatedCodec = codec
            pendingStartApp = initialPackage
        }

        try proc.run()

        do {
            let (videoConn, firstData) = try await connectVideoWithDummyRetry(port: localPort, sessionID: sessionID, proc: proc)
            let controlConn = try await ScrcpyAdbTransport.connectLoopback(port: localPort, queue: ioQueue)

            stateLock.withLock {
                guard activeSessionID == sessionID else {
                    videoConn.cancel()
                    controlConn.cancel()
                    return
                }
                videoConnection = videoConn
                controlConnection = controlConn
            }

            ioQueue.async { [weak self] in
                guard let self else { return }
                self.processVideoChunk(firstData, sessionID: sessionID)
                self.scheduleNextVideoRead(on: videoConn, sessionID: sessionID)
                if let pkg = self.stateLock.withLock({
                    let p = self.pendingStartApp
                    self.pendingStartApp = nil
                    return p
                }), !pkg.isEmpty {
                    self.sendControl(ScrcpyControlEncoder.startApp(packageName: pkg))
                }
            }
        } catch {
            stop()
            throw error
        }
    }

    private func buildServerProcess(
        adbPath: String,
        serial: String,
        scidHex: String,
        codec: VideoCodec,
        maxSize: Int,
        maxFps: Int,
        sessionID: UUID
    ) -> Process {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: adbPath)
        let remoteArgs = [
            "CLASSPATH=/data/local/tmp/scrcpy-server.jar",
            "app_process", "/", "com.genymobile.scrcpy.Server", Self.serverProtocolVersion,
            "scid=\(scidHex)", "tunnel_forward=true", "video=true", "audio=false", "control=true",
            "video_codec=\(codec == .h265 ? "h265" : "h264")", "max_size=\(maxSize)", "max_fps=\(maxFps)",
            "video_bit_rate=\(options.videoBitRate)", "send_dummy_byte=true", "send_device_meta=true",
            "send_frame_meta=true", "send_stream_meta=true"
        ] + options.extraArguments
        proc.arguments = ["-s", serial, "shell"] + remoteArgs

        let stderrPipe = Pipe()
        let stdoutPipe = Pipe()
        proc.standardError = stderrPipe
        proc.standardOutput = stdoutPipe

        let handler: @Sendable (FileHandle) -> Void = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty, let self else { return }
            self.onServerLog?(String(decoding: chunk, as: UTF8.self))
            self.stateLock.withLock {
                if self.serverStderrBuffer.count < 8192 {
                    self.serverStderrBuffer.append(chunk)
                }
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = handler
        stdoutPipe.fileHandleForReading.readabilityHandler = handler

        proc.terminationHandler = { [weak self] terminated in
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            guard let self else { return }
            let active = self.stateLock.withLock { self.activeSessionID == sessionID }
            if active, terminated.terminationReason != .uncaughtSignal {
                let output = self.stateLock.withLock {
                    String(data: self.serverStderrBuffer, encoding: .utf8) ?? ""
                }.trimmingCharacters(in: .whitespacesAndNewlines)
                if !output.isEmpty {
                    self.onStateChanged?(.failed(output))
                }
            }
        }
        return proc
    }

    private func connectVideoWithDummyRetry(port: UInt16, sessionID: UUID, proc: Process) async throws -> (NWConnection, Data) {
        for _ in 0..<40 {
            guard stateLock.withLock({ activeSessionID == sessionID }) else {
                throw ScrcpyStreamError.handshakeTimeout(reason: "Cancelled")
            }
            if !proc.isRunning {
                let msg = stateLock.withLock { String(data: serverStderrBuffer, encoding: .utf8) ?? "" }
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw ScrcpyStreamError.processExitedPrematurely(exitCode: proc.terminationStatus, output: msg)
            }
            if let conn = try? await ScrcpyAdbTransport.connectLoopback(port: port, queue: ioQueue) {
                if let firstData = await ScrcpyAdbTransport.receiveFirstBytes(on: conn) {
                    return (conn, firstData)
                }
                conn.cancel()
            }
            try await Task.sleep(nanoseconds: 60_000_000)
        }
        throw ScrcpyStreamError.handshakeTimeout(reason: "scrcpy video socket did not emit dummy byte")
    }

    private func scheduleNextVideoRead(on connection: NWConnection, sessionID: UUID) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 131_072) { [weak self] data, _, isComplete, error in
            guard let self, self.stateLock.withLock({ self.activeSessionID == sessionID }) else { return }
            if let data, !data.isEmpty {
                self.processVideoChunk(data, sessionID: sessionID)
            }
            if isComplete || error != nil {
                if let error { self.onStateChanged?(.failed(error.localizedDescription)) }
                return
            }
            self.scheduleNextVideoRead(on: connection, sessionID: sessionID)
        }
    }

    private func processVideoChunk(_ data: Data, sessionID: UUID) {
        guard stateLock.withLock({ activeSessionID == sessionID }), let demuxer else { return }
        do {
            for event in try demuxer.feed(data: data) {
                switch event {
                case .deviceHandshake(let deviceName, let codec):
                    negotiatedCodec = codec
                    decoder = try VideoToolboxDecoder(codec: codec)
                    onDeviceName?(deviceName, codec)
                case .sessionResize(let width, let height, _):
                    onVideoDimensionsChanged?(CGSize(width: width, height: height))
                    onStateChanged?(.streaming(width: width, height: height, codec: negotiatedCodec))
                case .frame(let packet):
                    guard let decoder else { continue }
                    if packet.isConfig {
                        try decoder.configureFromAnnexBConfig(packet.payload)
                    } else {
                        let pts = CMTime(value: CMTimeValue(packet.ptsMicroseconds), timescale: 1_000_000)
                        if let pixelBuffer = try decoder.decode(nalData: packet.payload, pts: pts) {
                            onPixelBuffer?(pixelBuffer, pts)
                        }
                    }
                }
            }
        } catch {
            onStateChanged?(.failed(error.localizedDescription))
        }
    }
}
