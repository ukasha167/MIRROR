import Foundation
import CryptoKit

/// Persistent trusted peer metadata and local Mac identity store.
public struct TrustedPeerRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var name: String
    public var model: String
    public let pairToken: String
    public let pairedAt: Date
    public var lastSeenAt: Date

    public init(id: String, name: String, model: String, pairToken: String, pairedAt: Date = Date(), lastSeenAt: Date = Date()) {
        self.id = id
        self.name = name
        self.model = model
        self.pairToken = pairToken
        self.pairedAt = pairedAt
        self.lastSeenAt = lastSeenAt
    }
}

/// Thread-safe `UserDefaults`-backed store of trusted paired Continuity devices.
public final class PairedPeerStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let peersKey = "dev.mirror.continuity.pairedPeers.v1"
    private let identityIdKey = "dev.mirror.continuity.localDeviceId.v1"
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func localDeviceIdentity() -> (id: String, name: String, fingerprint: String) {
        lock.lock()
        defer { lock.unlock() }
        let id: String
        if let existing = defaults.string(forKey: identityIdKey), !existing.isEmpty {
            id = existing
        } else {
            id = "mac-" + UUID().uuidString.lowercased()
            defaults.set(id, forKey: identityIdKey)
        }
        let hostName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let digest = SHA256.hash(data: Data(id.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return (id, hostName, String(hex.prefix(32)))
    }

    public func allPeers() -> [TrustedPeerRecord] {
        lock.lock()
        defer { lock.unlock() }
        guard let data = defaults.data(forKey: peersKey),
              let decoded = try? JSONDecoder().decode([TrustedPeerRecord].self, from: data) else {
            return []
        }
        return decoded
    }

    public func peer(id: String) -> TrustedPeerRecord? {
        allPeers().first { $0.id == id }
    }

    public func peer(matchingToken token: String) -> TrustedPeerRecord? {
        guard !token.isEmpty else { return nil }
        return allPeers().first { $0.pairToken == token }
    }

    public func save(_ peer: TrustedPeerRecord) {
        lock.lock()
        defer { lock.unlock() }
        var peers = (try? defaults.data(forKey: peersKey).flatMap { try JSONDecoder().decode([TrustedPeerRecord].self, from: $0) }) ?? []
        peers.removeAll { $0.id == peer.id }
        peers.append(peer)
        if let encoded = try? JSONEncoder().encode(peers) {
            defaults.set(encoded, forKey: peersKey)
        }
    }

    public func remove(id: String) {
        lock.lock()
        defer { lock.unlock() }
        var peers = (try? defaults.data(forKey: peersKey).flatMap { try JSONDecoder().decode([TrustedPeerRecord].self, from: $0) }) ?? []
        peers.removeAll { $0.id == id }
        if let encoded = try? JSONEncoder().encode(peers) {
            defaults.set(encoded, forKey: peersKey)
        }
    }
}
