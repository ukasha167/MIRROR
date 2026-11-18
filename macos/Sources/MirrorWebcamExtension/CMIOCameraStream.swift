import Foundation
import CoreMedia
import CoreMediaIO

/// Notifies host application of camera hardware demand changes.
public protocol CameraDemandDelegate: AnyObject, Sendable {
    func cameraDemandDidStart()
    func cameraDemandDidStop()
}

/// State tracking active consumer clients (Zoom, FaceTime, Meet) to power on/off phone camera.
public final class CameraDemandManager: @unchecked Sendable {
    private var activeClients: Set<String> = []
    private let lock = NSLock()
    public weak var delegate: CameraDemandDelegate?

    public private(set) var isStreaming: Bool = false
    public private(set) var lastStopTime: Date?

    public init(delegate: CameraDemandDelegate? = nil) {
        self.delegate = delegate
    }

    /// Called when a macOS video client (e.g. Zoom) starts consuming the source stream.
    public func clientDidConnect(_ clientId: String) {
        lock.lock()
        defer { lock.unlock() }

        let wasEmpty = activeClients.isEmpty
        activeClients.insert(clientId)

        if wasEmpty {
            isStreaming = true
            delegate?.cameraDemandDidStart()
        }
    }

    /// Called when a client stops consuming the stream.
    /// Ensures phone camera shutdown signal occurs within 100ms of last client disconnect.
    public func clientDidDisconnect(_ clientId: String) {
        lock.lock()
        defer { lock.unlock() }

        activeClients.remove(clientId)

        if activeClients.isEmpty && isStreaming {
            isStreaming = false
            lastStopTime = Date()
            delegate?.cameraDemandDidStop()
        }
    }

    public var clientCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return activeClients.count
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        activeClients.removeAll()
        isStreaming = false
    }
}

/// Camera format configuration for CoreMediaIO virtual camera streams.
public struct CameraStreamFormat: Sendable {
    public let width: Int32
    public let height: Int32
    public let maxFps: Float64
    public let mediaSubType: CMFormatDescription.MediaSubType

    public init(
        width: Int32 = 1920,
        height: Int32 = 1080,
        maxFps: Float64 = 60.0,
        mediaSubType: CMFormatDescription.MediaSubType = .init(string: "420v")
    ) {
        self.width = width
        self.height = height
        self.maxFps = maxFps
        self.mediaSubType = mediaSubType
    }

    public static let fullHD60 = CameraStreamFormat(width: 1920, height: 1080, maxFps: 60.0)
    public static let fullHD30 = CameraStreamFormat(width: 1920, height: 1080, maxFps: 30.0)
    public static let ultraHD4K = CameraStreamFormat(width: 3840, height: 2160, maxFps: 30.0)
}
