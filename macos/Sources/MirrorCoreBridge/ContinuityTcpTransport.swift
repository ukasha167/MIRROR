import Foundation
import Network
import Darwin

/// Typed errors raised by `ContinuityHostServer`.
public enum ContinuityHostError: Error, Sendable, LocalizedError, CustomStringConvertible {
    case pairingRejected(String)
    case connectionFailed(String)
    case invalidEndpoint(String)
    case timeout(String)

    public var errorDescription: String? { description }

    public var description: String {
        switch self {
        case .pairingRejected(let reason): return reason
        case .connectionFailed(let reason): return "Connection failed: \(reason)"
        case .invalidEndpoint(let ep): return "Invalid peer address: \(ep)"
        case .timeout(let msg): return "Timed out: \(msg)"
        }
    }
}

/// Discovered Continuity device (via Bonjour mDNS or USB ADB forward probe) before or after pairing.
public struct DiscoveredContinuityPeer: Sendable, Equatable, Identifiable {
    public let id: String
    public var name: String
    public var model: String
    public var host: String
    public var port: UInt16
    public var isUsb: Bool
    public var isPaired: Bool

    public init(id: String, name: String, model: String, host: String, port: UInt16, isUsb: Bool, isPaired: Bool) {
        self.id = id
        self.name = name
        self.model = model
        self.host = host
        self.port = port
        self.isUsb = isUsb
        self.isPaired = isPaired
    }
}

/// Actively connected and cryptographically/token-verified Android peer running the Continuity app.
public struct VerifiedConnectedPeer: Sendable, Equatable {
    public let id: String
    public let name: String
    public let model: String
    public let isUsb: Bool
    public var batteryLevel: Int
    public var isCharging: Bool
    public var adbSerial: String?
    public var mediaTitle: String?
    public var mediaArtist: String?
    public var mediaPlaying: Bool

    public init(
        id: String,
        name: String,
        model: String,
        isUsb: Bool,
        batteryLevel: Int = 100,
        isCharging: Bool = false,
        adbSerial: String? = nil,
        mediaTitle: String? = nil,
        mediaArtist: String? = nil,
        mediaPlaying: Bool = false
    ) {
        self.id = id
        self.name = name
        self.model = model
        self.isUsb = isUsb
        self.batteryLevel = batteryLevel
        self.isCharging = isCharging
        self.adbSerial = adbSerial
        self.mediaTitle = mediaTitle
        self.mediaArtist = mediaArtist
        self.mediaPlaying = mediaPlaying
    }
}

/// Line-delimited NDJSON wrapper around an `NWConnection` (or deterministic in-memory loopback for tests).
final class ContinuityTcpSession: @unchecked Sendable {
    let sessionId = UUID()
    let connection: NWConnection?
    let isUsbTransport: Bool

    var peerDeviceId: String?
    var peerName: String?
    var peerModel: String?
    var isAuthenticated = false
    var isReady = false
    var lastActivityAt = Date()

    private let queue: DispatchQueue
    private let bufferLock = NSLock()
    private var readBuffer = Data()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let loopbackSink: (@Sendable (ContinuityWireMessage) -> Void)?

    var onMessage: (@Sendable (ContinuityWireMessage) -> Void)?
    var onClosed: (@Sendable () -> Void)?

    init(connection: NWConnection, queue: DispatchQueue, isUsbTransport: Bool) {
        self.connection = connection
        self.queue = queue
        self.isUsbTransport = isUsbTransport
        self.loopbackSink = nil
    }

    init(isUsbTransport: Bool, queue: DispatchQueue, loopbackSink: @escaping @Sendable (ContinuityWireMessage) -> Void) {
        self.connection = nil
        self.queue = queue
        self.isUsbTransport = isUsbTransport
        self.loopbackSink = loopbackSink
    }

    func start(onReady: (@Sendable () -> Void)? = nil) {
        guard let connection else {
            onReady?()
            return
        }
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.isReady = true
                onReady?()
                self.scheduleRead()
            case .failed, .cancelled:
                self.isReady = false
                self.onClosed?()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func send(_ message: ContinuityWireMessage) {
        if let loopbackSink {
            loopbackSink(message)
            return
        }
        guard let connection, var data = try? encoder.encode(message) else { return }
        data.append(0x0A) // '\n'
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    func close() {
        isReady = false
        connection?.stateUpdateHandler = nil
        connection?.cancel()
    }

    private func scheduleRead() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.consumeChunk(data)
            }
            if isComplete || error != nil {
                self.close()
                self.onClosed?()
                return
            }
            self.scheduleRead()
        }
    }

    private func consumeChunk(_ chunk: Data) {
        let lines: [Data] = bufferLock.withLock {
            readBuffer.append(chunk)
            var extracted: [Data] = []
            while let newlineIndex = readBuffer.firstIndex(of: 0x0A) {
                let line = Data(readBuffer[..<newlineIndex])
                readBuffer.removeSubrange(...newlineIndex)
                if !line.isEmpty { extracted.append(line) }
            }
            if readBuffer.count > 1_048_576 {
                readBuffer.removeAll(keepingCapacity: false)
            }
            return extracted
        }

        lastActivityAt = Date()
        for line in lines {
            if let msg = try? decoder.decode(ContinuityWireMessage.self, from: line) {
                onMessage?(msg)
            }
        }
    }
}

/// Enumerates local IPv4 LAN addresses for embedding into QR endpoints.
enum LocalNetworkEnumerator {
    static func lanIPv4Addresses() -> [String] {
        var addresses: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let current = ptr {
            defer { ptr = current.pointee.ifa_next }
            guard let sa = current.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(current.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }

            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(sa, socklen_t(sa.pointee.sa_len), &hostBuffer, socklen_t(hostBuffer.count), nil, 0, NI_NUMERICHOST)
            guard result == 0 else { continue }
            let end = hostBuffer.firstIndex(of: 0) ?? hostBuffer.endIndex
            let ip = String(decoding: hostBuffer[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard !ip.hasPrefix("127."), !ip.hasPrefix("169.254.") else { continue }

            let ifName = String(cString: current.pointee.ifa_name)
            if ifName == "en0" {
                addresses.insert(ip, at: 0)
            } else if !addresses.contains(ip) {
                addresses.append(ip)
            }
        }
        return addresses
    }
}
