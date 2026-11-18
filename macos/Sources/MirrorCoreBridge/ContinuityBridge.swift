import Foundation
import CoreGraphics

/// State machine representing continuity bridge lifecycle.
public enum ContinuitySessionState: String, Sendable, Codable {
    case disconnected
    case discovering
    case pairing
    case connected
    case streaming
    case error
}

/// Physical USB ADB attachment detected on macOS prior to Continuity app verification.
/// Presence of a USB cable alone must NOT mark the device as connected.
public struct UsbAttachedDevice: Sendable, Equatable {
    public let serial: String
    public let model: String
    public let screenSize: CGSize?

    public init(serial: String, model: String, screenSize: CGSize? = nil) {
        self.serial = serial
        self.model = model
        self.screenSize = screenSize
    }
}

/// Immutable snapshot returned by `LiveContinuityBridge.refreshConnectionState()`.
public struct ContinuitySnapshot: Sendable, Equatable {
    public let sessionState: ContinuitySessionState
    public let activeDevice: PairedDevice?
    public let usbAttached: UsbAttachedDevice?
    public let discoveredPeers: [DiscoveredContinuityPeer]
    public let trustedPeers: [TrustedPeerRecord]

    public init(
        sessionState: ContinuitySessionState,
        activeDevice: PairedDevice?,
        usbAttached: UsbAttachedDevice?,
        discoveredPeers: [DiscoveredContinuityPeer],
        trustedPeers: [TrustedPeerRecord]
    ) {
        self.sessionState = sessionState
        self.activeDevice = activeDevice
        self.usbAttached = usbAttached
        self.discoveredPeers = discoveredPeers
        self.trustedPeers = trustedPeers
    }
}

/// Protocol unifying Continuity Core (Rust UniFFI) with SwiftUI/AppKit views.
public protocol ContinuityBridgeProtocol: Sendable {
    var sessionState: ContinuitySessionState { get async }
    var activeDevice: PairedDevice? { get async }
    var pairedDevices: [PairedDevice] { get async }

    func startDiscovery() async throws
    func stopDiscovery() async
    func pairDevice(id: String, pin: String?) async throws -> Bool
    func disconnect() async

    func sendClipboard(item: ClipboardItem) async throws
    func fetchLazyClipboardData(metadata: LazyClipboardMetadata) async throws -> Data
    func dismissNotification(id: String) async throws
    func sendNotificationReply(id: String, text: String) async throws

    func startMirroring(deviceId: String, appPackage: String?) async throws
    func stopMirroring() async throws
}

/// Deterministic in-memory mock bridge for hardware-free SwiftUI previews and XCTest suites.
public actor MockContinuityBridge: ContinuityBridgeProtocol {
    public var sessionState: ContinuitySessionState = .disconnected
    public var activeDevice: PairedDevice?
    public var pairedDevices: [PairedDevice] = []
    public var sentClipboards: [ClipboardItem] = []
    public var dismissedNotifications: [String] = []
    public var sentReplies: [(id: String, text: String)] = []
    public var isMirroring: Bool = false
    public var mirroredAppPackage: String?

    public init() {
        let defaultDevice = PairedDevice(
            id: "pixel-9-pro",
            name: "Pixel 9 Pro",
            model: "Pixel 9 Pro XL",
            transport: .wifiLan,
            certificateFingerprint: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            batteryLevel: 0.88,
            isCharging: false,
            connectionStatus: .connected,
            ipAddress: "192.168.1.105",
            port: 53317
        )
        self.pairedDevices = [defaultDevice]
        self.activeDevice = defaultDevice
        self.sessionState = .connected
    }

    public func startDiscovery() async throws { sessionState = .discovering }

    public func stopDiscovery() async {
        sessionState = activeDevice != nil ? .connected : .disconnected
    }

    public func pairDevice(id: String, pin: String?) async throws -> Bool {
        sessionState = .pairing
        if pin == "0000" {
            sessionState = .error
            return false
        }
        let newDev = PairedDevice(
            id: id,
            name: "Paired Phone \(id)",
            model: "Android 15 Device",
            transport: .wifiLan,
            certificateFingerprint: "fingerprint-\(id)",
            connectionStatus: .connected
        )
        pairedDevices.append(newDev)
        activeDevice = newDev
        sessionState = .connected
        return true
    }

    public func disconnect() async {
        sessionState = .disconnected
        activeDevice = nil
        isMirroring = false
    }

    public func sendClipboard(item: ClipboardItem) async throws { sentClipboards.append(item) }

    public func fetchLazyClipboardData(metadata: LazyClipboardMetadata) async throws -> Data {
        Data(repeating: 0x42, count: Int(min(metadata.byteSize, 1024)))
    }

    public func dismissNotification(id: String) async throws { dismissedNotifications.append(id) }

    public func sendNotificationReply(id: String, text: String) async throws {
        sentReplies.append((id: id, text: text))
    }

    public func startMirroring(deviceId: String, appPackage: String?) async throws {
        isMirroring = true
        mirroredAppPackage = appPackage
        sessionState = .streaming
    }

    public func stopMirroring() async throws {
        isMirroring = false
        mirroredAppPackage = nil
        sessionState = .connected
    }
}
