import Foundation

/// Remembers the phone's last Wi-Fi address between launches.
public protocol SavedPhoneStore: Sendable {
    func loadAddress() -> String?
    func saveAddress(_ address: String)
}

public struct UserDefaultsPhoneStore: SavedPhoneStore {
    private let key = "MirrorDesk.phoneWifiAddress"
    public init() {}
    public func loadAddress() -> String? { UserDefaults.standard.string(forKey: key) }
    public func saveAddress(_ address: String) { UserDefaults.standard.set(address, forKey: key) }
}

public struct PhoneEndpoint: Equatable, Sendable {
    /// The adb serial to pass to `-s` (hardware serial over USB, `ip:port` over Wi-Fi).
    public var serial: String
    public var transport: AdbDevice.Transport
    public var model: String
}

public enum PhoneLocatorError: Error, Equatable, CustomStringConvertible {
    case noPhone
    case unauthorized(serial: String)

    public var description: String {
        switch self {
        case .noPhone:
            return "No phone found. Plug it in over USB once so the Mac can switch it to Wi-Fi."
        case .unauthorized(let serial):
            return "Phone \(serial) has not allowed this Mac. Unlock it and accept the USB debugging prompt."
        }
    }
}

/// Finds the phone over USB or a saved Wi-Fi address.
///
/// While the cable is in, it reads the phone's Wi-Fi address and runs `adb tcpip`, so the
/// cable can come out later and `adb connect` still works (until the phone reboots).
public struct PhoneLocator: Sendable {
    public static let tcpipPort = 5555

    let adb: AdbClient
    let store: any SavedPhoneStore

    public init(adb: AdbClient, store: any SavedPhoneStore = UserDefaultsPhoneStore()) {
        self.adb = adb
        self.store = store
    }

    public func locate() async throws -> PhoneEndpoint {
        let devices = try await adb.devices()

        if let usb = devices.first(where: { $0.transport == .usb }) {
            guard usb.isReady else { throw PhoneLocatorError.unauthorized(serial: usb.serial) }
            await prepareWifi(usb: usb, alreadyOnWifi: devices.contains { $0.transport == .wifi && $0.isReady })
            // Prefer the cable while it is plugged in: more bandwidth, lower latency.
            return endpoint(usb)
        }

        if let wifi = devices.first(where: { $0.transport == .wifi && $0.isReady }) {
            return endpoint(wifi)
        }

        if let address = store.loadAddress(),
           (try? await adb.connect(host: address, port: Self.tcpipPort)) == true {
            let serial = "\(address):\(Self.tcpipPort)"
            let model = (try? await adb.devices())?.first { $0.serial == serial }?.model
            return PhoneEndpoint(serial: serial, transport: .wifi, model: model ?? "Phone")
        }

        throw PhoneLocatorError.noPhone
    }

    /// Saves the phone's Wi-Fi address and switches adbd to TCP. Failures are not fatal:
    /// the USB connection still works without them.
    private func prepareWifi(usb: AdbDevice, alreadyOnWifi: Bool) async {
        guard let address = try? await adb.wifiAddress(serial: usb.serial) else { return }
        store.saveAddress(address)
        if alreadyOnWifi { return }
        do {
            try await adb.enableTcpip(serial: usb.serial, port: Self.tcpipPort)
            // adbd restarts on the phone; the USB transport drops for about a second.
            try await Task.sleep(nanoseconds: 1_500_000_000)
            _ = try await adb.connect(host: address, port: Self.tcpipPort)
        } catch {
            // Leave the phone on USB only.
        }
    }

    private func endpoint(_ device: AdbDevice) -> PhoneEndpoint {
        PhoneEndpoint(serial: device.serial, transport: device.transport, model: device.model ?? "Phone")
    }
}
