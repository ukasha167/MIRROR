import Foundation

/// Sets up the phone app `dev.mirror.companion` over USB (android/companion).
///
/// After a reboot Android forgets `adb tcpip`, so the Mac cannot reach the phone without
/// the cable. The companion app turns Wireless debugging back on when the phone joins an
/// approved Wi-Fi network; the Mac then finds it through `_adb-tls-connect._tcp`. For that
/// the app needs permissions only adb can grant:
///
/// - `WRITE_SECURE_SETTINGS` to write `adb_wifi_enabled`.
/// - Fine and background location, because Android hides the Wi-Fi name from apps without them.
///
/// Then the Mac asks the app to approve the network the phone is on now.
public struct CompanionSetup: Sendable {
    public static let package = "dev.mirror.companion"
    static let approveAction = "dev.mirror.companion.APPROVE_NETWORK"
    static let receiver = "dev.mirror.companion/.CompanionReceiver"
    static let permissions = [
        "android.permission.WRITE_SECURE_SETTINGS",
        "android.permission.ACCESS_FINE_LOCATION",
        // Android only grants background location once fine location is granted.
        "android.permission.ACCESS_BACKGROUND_LOCATION",
    ]

    public enum Outcome: Equatable, Sendable, CustomStringConvertible {
        case notInstalled
        case approved(network: String)
        /// Permissions granted, but the app could not approve the network (for example
        /// location is off on the phone, or the phone is not on Wi-Fi).
        case notApproved(reason: String)
        case failed(String)

        public var description: String {
            switch self {
            case .notInstalled: return "companion app not installed"
            case .approved(let network): return "approved Wi-Fi network \(network)"
            case .notApproved(let reason): return "permissions granted, network not approved: \(reason)"
            case .failed(let message): return "setup failed: \(message)"
            }
        }
    }

    let adb: AdbClient

    public init(adb: AdbClient) { self.adb = adb }

    public func isInstalled(serial: String) async -> Bool {
        let out = try? await adb.adb(["-s", serial, "shell", "pm", "path", Self.package])
        return out?.hasPrefix("package:") == true
    }

    /// `adb install -r`: replaces an older build and keeps its data and grants.
    public func install(serial: String, apk: String) async throws {
        try await adb.adb(["-s", serial, "install", "-r", apk])
    }

    public func run(serial: String) async -> Outcome {
        guard await isInstalled(serial: serial) else { return .notInstalled }
        do {
            for permission in Self.permissions {
                try await adb.adb(["-s", serial, "shell", "pm", "grant", Self.package, permission])
            }
            let out = try await adb.adb([
                "-s", serial, "shell", "am", "broadcast", "-a", Self.approveAction, "-n", Self.receiver,
            ])
            return Self.parseApproveResult(out)
        } catch {
            return .failed("\(error)")
        }
    }

    /// Reads the receiver's result data from `am broadcast`, for example:
    /// ```
    /// Broadcasting: Intent { act=dev.mirror.companion.APPROVE_NETWORK flg=0x400000 cmp=... }
    /// Broadcast completed: result=-1, data="approved:HUAWEI-5G-9fDV"
    /// ```
    /// No `data=` means the receiver did not run (an older app build, or the broadcast was blocked).
    static func parseApproveResult(_ output: String) -> Outcome {
        guard let start = output.range(of: "data=\""),
              let end = output.range(of: "\"", options: .backwards),
              end.lowerBound > start.upperBound else {
            return .failed("no reply from the companion app")
        }
        let data = String(output[start.upperBound..<end.lowerBound])
        if data.hasPrefix("approved:") { return .approved(network: String(data.dropFirst("approved:".count))) }
        if data.hasPrefix("error:") { return .notApproved(reason: String(data.dropFirst("error:".count))) }
        return .failed("unexpected reply: \(data)")
    }
}
