import Foundation
import CryptoKit

/// UKEY2 handshake message types.
public enum UKEY2MessageType: UInt8, Sendable {
    case clientInit = 1
    case serverInit = 2
    case clientFinish = 3
}

/// State of the UKEY2 cryptographic handshake.
public enum UKEY2State: Sendable, Equatable {
    case idle
    case receivedClientInit(clientPublicKey: Data)
    case sentServerInit(serverPublicKey: Data)
    case authenticated(authPin: String, sessionKey: Data)
    case error(String)
}

/// UKEY2 session performing ECDH key exchange and deriving mutual authentication PIN.
public final class UKEY2Session: @unchecked Sendable {
    public private(set) var state: UKEY2State = .idle
    private var clientKey: Data?
    private var serverPrivateKey: Curve25519.KeyAgreement.PrivateKey?
    private var derivedSessionKey: SymmetricKey?

    public init() {}

    /// Processes an incoming UKEY2 ClientInit packet.
    public func processClientInit(payload: Data) throws -> Data {
        guard payload.count >= 32 else {
            state = .error("UKEY2 ClientInit payload truncated (\(payload.count) < 32 bytes)")
            throw UKEY2Error.invalidClientInit
        }

        // Extract client public key (last 32 bytes)
        let clientPubData = payload.suffix(32)
        self.clientKey = clientPubData
        self.state = .receivedClientInit(clientPublicKey: clientPubData)

        // Generate ephemeral Curve25519 keypair for ServerInit
        let serverPriv = Curve25519.KeyAgreement.PrivateKey()
        self.serverPrivateKey = serverPriv
        let serverPub = serverPriv.publicKey.rawRepresentation

        // Build ServerInit response packet:
        // [Byte 0: type = 2 (ServerInit)] + [32 bytes server public key]
        var response = Data([UKEY2MessageType.serverInit.rawValue])
        response.append(serverPub)

        self.state = .sentServerInit(serverPublicKey: serverPub)
        return response
    }

    /// Processes an incoming UKEY2 ClientFinish packet and finishes key derivation.
    public func processClientFinish(payload: Data) throws -> (authPin: String, sessionKey: Data) {
        guard case .sentServerInit = state,
              let clientPubData = clientKey,
              let serverPriv = serverPrivateKey else {
            state = .error("UKEY2 ClientFinish received in unexpected state")
            throw UKEY2Error.unexpectedState
        }

        guard let clientPublicKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: clientPubData) else {
            state = .error("Failed to parse client Curve25519 public key")
            throw UKEY2Error.invalidKey
        }

        guard let sharedSecret = try? serverPriv.sharedSecretFromKeyAgreement(with: clientPublicKey) else {
            state = .error("ECDH key agreement failed")
            throw UKEY2Error.keyAgreementFailed
        }

        // Derive session key and 4-digit PIN via HKDF-SHA256
        let salt = "UKEY2_QuickShare_Salt".data(using: .utf8)!
        let sessionKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: "SessionKey".data(using: .utf8)!,
            outputByteCount: 32
        )
        self.derivedSessionKey = sessionKey

        let authKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: "AuthToken".data(using: .utf8)!,
            outputByteCount: 4
        )

        let pinValue = authKey.withUnsafeBytes { ptr -> UInt32 in
            ptr.load(as: UInt32.self).bigEndian
        }
        let authPin = String(format: "%04d", pinValue % 10000)

        let keyData = sessionKey.withUnsafeBytes { Data($0) }
        self.state = .authenticated(authPin: authPin, sessionKey: keyData)

        return (authPin: authPin, sessionKey: keyData)
    }

    public var isAuthenticated: Bool {
        if case .authenticated = state { return true }
        return false
    }
}

public enum UKEY2Error: Error, Sendable {
    case invalidClientInit
    case unexpectedState
    case invalidKey
    case keyAgreementFailed
}
