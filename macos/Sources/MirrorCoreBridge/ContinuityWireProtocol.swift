import Foundation
import CryptoKit

/// Errors thrown while parsing or encoding Mirror Continuity pairing payloads or wire messages.
public enum ContinuityPairingError: Error, Sendable, LocalizedError, CustomStringConvertible {
    case invalidQrPrefix
    case missingField(String)
    case invalidPinFormat(expectedLength: Int, actual: String)
    case qrExpired(expiredAt: Int64)
    case malformedWirePacket(String)

    public var errorDescription: String? { description }

    public var description: String {
        switch self {
        case .invalidQrPrefix:
            return "QR payload must start with WIFI:T:ADB;"
        case .missingField(let field):
            return "Missing required pairing field '\(field)'"
        case .invalidPinFormat(let expected, let actual):
            return "Expected \(expected)-digit pair code, got '\(actual)'"
        case .qrExpired(let ts):
            return "Pairing QR code expired at epoch \(ts)"
        case .malformedWirePacket(let msg):
            return "Malformed Continuity wire packet: \(msg)"
        }
    }
}

/// Endpoint candidate carried inside a Continuity QR payload (`host:port@transport`).
public struct ContinuityEndpointCandidate: Codable, Sendable, Equatable, Hashable {
    public enum Kind: String, Codable, Sendable {
        case lan
        case ncm
        case usb
    }

    public let address: String
    public let kind: Kind

    public init(address: String, kind: Kind) {
        self.address = address
        self.kind = kind
    }

    public var host: String? {
        guard let idx = address.lastIndex(of: ":") else { return address.isEmpty ? nil : address }
        return String(address[..<idx])
    }

    public var port: UInt16? {
        guard let idx = address.lastIndex(of: ":") else { return nil }
        return UInt16(address[address.index(after: idx)...])
    }
}

/// Canonical QR payload matching Rust `ContinuityPairingQr`:
/// `WIFI:T:ADB;S:<svc>;P:<pass>;ID:<id>;NAME:<name>;FP:<hex>;EP:<addr@lan,...>;EXP:<ts>;;`
public struct ContinuityPairingPayload: Sendable, Equatable {
    public let serviceName: String
    public let passcode: String
    public let deviceId: String
    public let deviceName: String
    public let fingerprint: String
    public let endpoints: [ContinuityEndpointCandidate]
    public let expiresAt: Int64

    public init(
        serviceName: String = "_mirror-cont._tcp",
        passcode: String,
        deviceId: String,
        deviceName: String,
        fingerprint: String,
        endpoints: [ContinuityEndpointCandidate],
        expiresAt: Int64
    ) {
        self.serviceName = serviceName
        self.passcode = passcode
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.fingerprint = fingerprint
        self.endpoints = endpoints
        self.expiresAt = expiresAt
    }

    public func isExpired(nowEpochSeconds: Int64 = Int64(Date().timeIntervalSince1970)) -> Bool {
        expiresAt > 0 && nowEpochSeconds > expiresAt
    }
}

/// QR URI codec & 6-digit PIN helper shared across pairing flows.
public enum ContinuityPairingCodec {
    public static func generatePin() -> String {
        String(format: "%06d", Int.random(in: 0..<1_000_000))
    }

    public static func normalizePin(_ input: String) -> String {
        String(input.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }.prefix(6))
    }

    public static func formatPin(_ pin: String) -> String {
        let digits = normalizePin(pin)
        guard digits.count == 6 else { return digits }
        let mid = digits.index(digits.startIndex, offsetBy: 3)
        return "\(digits[..<mid]) \(digits[mid...])"
    }

    public static func encodeQR(_ payload: ContinuityPairingPayload) -> String {
        let epString = payload.endpoints
            .map { "\(escape($0.address))@\($0.kind.rawValue)" }
            .joined(separator: ",")
        return [
            "WIFI:T:ADB",
            "S:\(escape(payload.serviceName))",
            "P:\(escape(payload.passcode))",
            "ID:\(escape(payload.deviceId))",
            "NAME:\(escape(payload.deviceName))",
            "FP:\(escape(payload.fingerprint))",
            "EP:\(epString)",
            "EXP:\(payload.expiresAt)",
            ";"
        ].joined(separator: ";")
    }

    public static func decodeQR(_ raw: String, validateExpiry: Bool = true, nowEpochSeconds: Int64 = Int64(Date().timeIntervalSince1970)) throws -> ContinuityPairingPayload {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("WIFI:") else {
            throw ContinuityPairingError.invalidQrPrefix
        }

        let body = String(trimmed.dropFirst(5))
        let tokens = splitUnescaped(body, separator: ";")
        var fields: [String: String] = [:]
        for token in tokens where !token.isEmpty {
            guard let colon = firstUnescapedColon(in: token) else { continue }
            let key = String(token[..<colon])
            let val = String(token[token.index(after: colon)...])
            fields[key] = val
        }

        guard fields["T"] == "ADB" else { throw ContinuityPairingError.invalidQrPrefix }
        guard let svc = fields["S"].map(unescape), !svc.isEmpty else { throw ContinuityPairingError.missingField("S") }
        guard let rawPin = fields["P"].map(unescape) else { throw ContinuityPairingError.missingField("P") }
        let pin = normalizePin(rawPin)
        guard pin.count == 6 else { throw ContinuityPairingError.invalidPinFormat(expectedLength: 6, actual: rawPin) }
        guard let devId = fields["ID"].map(unescape), !devId.isEmpty else { throw ContinuityPairingError.missingField("ID") }
        guard let name = fields["NAME"].map(unescape), !name.isEmpty else { throw ContinuityPairingError.missingField("NAME") }
        guard let fp = fields["FP"].map(unescape), !fp.isEmpty else { throw ContinuityPairingError.missingField("FP") }
        guard let expStr = fields["EXP"], let exp = Int64(expStr) else { throw ContinuityPairingError.missingField("EXP") }

        if validateExpiry && exp > 0 && nowEpochSeconds > exp {
            throw ContinuityPairingError.qrExpired(expiredAt: exp)
        }

        var endpoints: [ContinuityEndpointCandidate] = []
        if let rawEps = fields["EP"], !rawEps.isEmpty {
            for entry in splitUnescaped(rawEps, separator: ",") where !entry.isEmpty {
                let parts = entry.split(separator: "@", maxSplits: 1).map(String.init)
                let addr = unescape(parts[0])
                let kind = parts.count > 1 ? (ContinuityEndpointCandidate.Kind(rawValue: parts[1]) ?? .lan) : .lan
                endpoints.append(ContinuityEndpointCandidate(address: addr, kind: kind))
            }
        }

        return ContinuityPairingPayload(
            serviceName: svc,
            passcode: pin,
            deviceId: devId,
            deviceName: name,
            fingerprint: fp,
            endpoints: endpoints,
            expiresAt: exp
        )
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ":", with: "\\:")
            .replacingOccurrences(of: ",", with: "\\,")
    }

    private static func unescape(_ value: String) -> String {
        var out = ""
        var escaped = false
        for ch in value {
            if escaped {
                out.append(ch)
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else {
                out.append(ch)
            }
        }
        if escaped { out.append("\\") }
        return out
    }

    private static func splitUnescaped(_ s: String, separator: Character) -> [String] {
        var result: [String] = []
        var current = ""
        var escaped = false
        for ch in s {
            if escaped {
                current.append("\\")
                current.append(ch)
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == separator {
                result.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        if escaped { current.append("\\") }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func firstUnescapedColon(in s: String) -> String.Index? {
        var escaped = false
        for idx in s.indices {
            let ch = s[idx]
            if escaped {
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == ":" {
                return idx
            }
        }
        return nil
    }
}

/// NDJSON control/presence frame exchanged over Continuity TCP links (LAN mDNS or USB ADB tunnel).
public struct ContinuityWireMessage: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case hello
        case helloAck = "hello_ack"
        case pairRequest = "pair_request"
        case pairResponse = "pair_response"
        case statusUpdate = "status_update"
        case ping
        case pong
        case bye
        case mediaUpdate = "media_update"
        case clipboardSync = "clipboard_sync"
    }

    public var type: Kind
    public var deviceId: String
    public var deviceName: String
    public var deviceModel: String
    public var role: String
    public var code: String?
    public var pairToken: String?
    public var accepted: Bool?
    public var reason: String?
    public var batteryLevel: Int?
    public var isCharging: Bool?
    public var adbSerial: String?
    public var listeningPort: UInt16?
    public var mediaTitle: String?
    public var mediaArtist: String?
    public var mediaPlaying: Bool?
    public var clipboardText: String?
    public var timestampMs: Int64?

    public init(
        type: Kind,
        deviceId: String,
        deviceName: String,
        deviceModel: String,
        role: String,
        code: String? = nil,
        pairToken: String? = nil,
        accepted: Bool? = nil,
        reason: String? = nil,
        batteryLevel: Int? = nil,
        isCharging: Bool? = nil,
        adbSerial: String? = nil,
        listeningPort: UInt16? = nil,
        mediaTitle: String? = nil,
        mediaArtist: String? = nil,
        mediaPlaying: Bool? = nil,
        clipboardText: String? = nil,
        timestampMs: Int64? = nil
    ) {
        self.type = type
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.deviceModel = deviceModel
        self.role = role
        self.code = code
        self.pairToken = pairToken
        self.accepted = accepted
        self.reason = reason
        self.batteryLevel = batteryLevel
        self.isCharging = isCharging
        self.adbSerial = adbSerial
        self.listeningPort = listeningPort
        self.mediaTitle = mediaTitle
        self.mediaArtist = mediaArtist
        self.mediaPlaying = mediaPlaying
        self.clipboardText = clipboardText
        self.timestampMs = timestampMs
    }
}
