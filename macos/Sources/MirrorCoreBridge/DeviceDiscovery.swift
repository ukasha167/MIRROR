import Foundation

/// Transport medium used to connect to the companion device.
public enum DeviceTransport: String, Sendable, Codable, CaseIterable {
    case usbAdb
    case usbNcm
    case wifiLan
    case ble
}

/// Active connection state of a paired device.
public enum DeviceConnectionStatus: String, Sendable, Codable {
    case disconnected
    case connecting
    case connected
    case streaming
}

/// Information describing an authenticated companion device.
public struct PairedDevice: Sendable, Identifiable, Codable, Hashable {
    public let id: String
    public let name: String
    public let model: String
    public let transport: DeviceTransport
    public let certificateFingerprint: String
    public var batteryLevel: Double? // 0.0 to 1.0
    public var isCharging: Bool
    public var connectionStatus: DeviceConnectionStatus
    public var ipAddress: String?
    public var port: UInt16?

    public init(
        id: String,
        name: String,
        model: String,
        transport: DeviceTransport,
        certificateFingerprint: String,
        batteryLevel: Double? = nil,
        isCharging: Bool = false,
        connectionStatus: DeviceConnectionStatus = .disconnected,
        ipAddress: String? = nil,
        port: UInt16? = nil
    ) {
        self.id = id
        self.name = name
        self.model = model
        self.transport = transport
        self.certificateFingerprint = certificateFingerprint
        self.batteryLevel = batteryLevel
        self.isCharging = isCharging
        self.connectionStatus = connectionStatus
        self.ipAddress = ipAddress
        self.port = port
    }
}

/// Device discovered on LAN or USB before or during pairing.
public struct DiscoveredDevice: Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let transport: DeviceTransport
    public let address: String
    public let port: UInt16
    public let txtRecord: [String: String]

    public init(
        id: String,
        name: String,
        transport: DeviceTransport,
        address: String,
        port: UInt16,
        txtRecord: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.transport = transport
        self.address = address
        self.port = port
        self.txtRecord = txtRecord
    }
}

/// State of the background device discovery service.
public enum DiscoveryState: Sendable, Equatable {
    case idle
    case searching
    case devicesFound([String])
    case failed(String)
}
