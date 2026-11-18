import Foundation

#if canImport(FSKit)
import FSKit
#endif

/// State of the mounted Android FSKit virtual volume.
public enum VolumeMountStatus: String, Sendable, Codable {
    case unmounted
    case mounting
    case mounted
    case unmounting
    case failed
}

/// Metadata describing an Android storage volume exposed in Finder sidebar.
public struct AndroidVolumeInfo: Sendable, Equatable {
    public let volumeName: String
    public let mountPoint: URL
    public let totalBytes: Int64
    public let freeBytes: Int64
    public let isReadOnly: Bool

    public init(
        volumeName: String = "Android Storage",
        mountPoint: URL = URL(fileURLWithPath: "/Volumes/Android Storage"),
        totalBytes: Int64 = 256 * 1024 * 1024 * 1024, // 256 GB
        freeBytes: Int64 = 128 * 1024 * 1024 * 1024,  // 128 GB
        isReadOnly: Bool = false
    ) {
        self.volumeName = volumeName
        self.mountPoint = mountPoint
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.isReadOnly = isReadOnly
    }
}

/// Volume mount manager for macOS FSKit integration.
public final class FSKitVolumeManager: @unchecked Sendable {
    private var volumeInfo: AndroidVolumeInfo?
    public private(set) var status: VolumeMountStatus = .unmounted
    private let lock = NSLock()

    public init() {}

    /// Initiates volume mount in Finder sidebar.
    public func mount(volume: AndroidVolumeInfo) throws {
        lock.lock()
        defer { lock.unlock() }

        status = .mounting
        self.volumeInfo = volume
        // On macOS 15.4+, FSKit FSUnaryFileSystem mounts user-space filesystem
        status = .mounted
    }

    /// Unmounts volume from Finder sidebar.
    public func unmount() throws {
        lock.lock()
        defer { lock.unlock() }

        guard status == .mounted else { return }
        status = .unmounting
        self.volumeInfo = nil
        status = .unmounted
    }

    public var currentVolume: AndroidVolumeInfo? {
        lock.lock()
        defer { lock.unlock() }
        return volumeInfo
    }

    public var isMounted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return status == .mounted
    }
}
