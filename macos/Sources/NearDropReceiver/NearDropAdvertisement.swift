import Foundation

/// Configuration for Google Quick Share mDNS LAN advertisement.
public struct NearDropAdvertisementConfig: Sendable, Equatable {
    /// Quick Share mDNS service type.
    public static let serviceType = "_FC9F5ED42C8A._tcp.local."

    public let endpointId: String
    public let deviceName: String
    public let port: UInt16
    public let isVisibleToEveryone: Bool

    public init(
        endpointId: String = "MR01",
        deviceName: String = Host.current().localizedName ?? "Mac",
        port: UInt16 = 52319,
        isVisibleToEveryone: Bool = true
    ) {
        self.endpointId = endpointId
        self.deviceName = deviceName
        self.port = port
        self.isVisibleToEveryone = isVisibleToEveryone
    }

    /// Generates the raw Endpoint Info payload packed into mDNS TXT record 'n'.
    ///
    /// ### Quick Share Endpoint Info Layout:
    /// - `Byte 0`: Format version (1) | Device Type (0 = unknown, 1 = phone, 2 = tablet, 3 = laptop)
    /// - `Bytes 1..N`: UTF-8 Device Name length (1 byte) + Device Name bytes
    public func makeEndpointInfo() -> Data {
        var data = Data()
        // Version 1, Device Type = Laptop (3) -> (1 << 3) | 3 = 0x0B
        data.append(0x0B)

        let nameBytes = [UInt8](deviceName.utf8)
        let nameLen = UInt8(min(nameBytes.count, 32))
        data.append(nameLen)
        data.append(contentsOf: nameBytes.prefix(Int(nameLen)))

        return data
    }

    /// Formats the mDNS TXT record map.
    public var txtRecord: [String: String] {
        let endpointBase64 = makeEndpointInfo().base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return ["n": endpointBase64]
    }
}

/// Controller advertising Quick Share receiver service on the local Wi-Fi LAN.
public final class NearDropAdvertiser: @unchecked Sendable {
    public let config: NearDropAdvertisementConfig
    public private(set) var isAdvertising: Bool = false
    private let lock = NSLock()

    public init(config: NearDropAdvertisementConfig = NearDropAdvertisementConfig()) {
        self.config = config
    }

    public func startAdvertising() {
        lock.lock()
        defer { lock.unlock() }
        isAdvertising = true
    }

    public func stopAdvertising() {
        lock.lock()
        defer { lock.unlock() }
        isAdvertising = false
    }
}
