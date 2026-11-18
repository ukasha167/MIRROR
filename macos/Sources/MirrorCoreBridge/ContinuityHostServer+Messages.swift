import Foundation
import CryptoKit

extension ContinuityHostServer {
    /// Deterministic hardware-free entry point for unit testing handshake and pairing rules.
    func dispatchTestMessage(_ msg: ContinuityWireMessage, session: ContinuityTcpSession) {
        queue.sync {
            self.sessions[session.sessionId] = session
            self.handleMessage(msg, on: session)
        }
    }

    func handleMessage(_ msg: ContinuityWireMessage, on session: ContinuityTcpSession) {
        guard msg.role == "android" || msg.type == .ping || msg.type == .pong || msg.type == .bye else { return }
        session.peerDeviceId = msg.deviceId
        session.peerName = msg.deviceName
        session.peerModel = msg.deviceModel

        switch msg.type {
        case .hello:
            handleHello(msg, on: session)
        case .helloAck:
            handleHelloAck(msg, on: session)
        case .pairRequest:
            handlePairRequest(msg, on: session)
        case .pairResponse:
            handlePairResponse(msg, on: session)
        case .statusUpdate:
            guard session.isAuthenticated, var peer = connectedPeer else { return }
            if let lvl = msg.batteryLevel { peer.batteryLevel = lvl }
            if let chg = msg.isCharging { peer.isCharging = chg }
            if let serial = msg.adbSerial, !serial.isEmpty { peer.adbSerial = serial }
            publishConnectedPeer(peer)
        case .mediaUpdate:
            guard session.isAuthenticated, var peer = connectedPeer else { return }
            peer.mediaTitle = msg.mediaTitle
            peer.mediaArtist = msg.mediaArtist
            peer.mediaPlaying = msg.mediaPlaying ?? false
            publishConnectedPeer(peer)
            onRemoteMediaChanged?(peer.mediaTitle, peer.mediaArtist, peer.mediaPlaying)
        case .clipboardSync:
            if session.isAuthenticated, let text = msg.clipboardText, !text.isEmpty {
                onRemoteClipboardReceived?(text)
            }
        case .ping:
            session.send(makeMessage(type: .pong))
        case .pong:
            break
        case .bye:
            session.close()
            clearActiveSessionIfMatching(session.sessionId)
        }
    }

    private func handleHello(_ msg: ContinuityWireMessage, on session: ContinuityTcpSession) {
        let matchedPeer = peerStore.peer(id: msg.deviceId).flatMap { stored in
            (msg.pairToken == stored.pairToken && !stored.pairToken.isEmpty) ? stored : nil
        }
        if let trusted = matchedPeer {
            var ack = makeMessage(type: .helloAck, accepted: true)
            ack.pairToken = trusted.pairToken
            ack.adbSerial = localAdbSerial
            session.send(ack)
            promoteVerifiedSession(session, msg: msg)
        } else {
            var ack = makeMessage(type: .helloAck, accepted: false, reason: "Pairing required")
            ack.adbSerial = localAdbSerial
            session.send(ack)
            recordDiscovered(msg: msg, on: session, isPaired: false)
        }
    }

    private func handleHelloAck(_ msg: ContinuityWireMessage, on session: ContinuityTcpSession) {
        if msg.accepted == true,
           let token = msg.pairToken,
           let stored = peerStore.peer(matchingToken: token) ?? peerStore.peer(id: msg.deviceId),
           stored.pairToken == token {
            promoteVerifiedSession(session, msg: msg)
        } else {
            recordDiscovered(msg: msg, on: session, isPaired: false)
        }
    }

    private func handlePairRequest(_ msg: ContinuityWireMessage, on session: ContinuityTcpSession) {
        let entered = ContinuityPairingCodec.normalizePin(msg.code ?? "")
        let now = Int64(Date().timeIntervalSince1970)
        let (expected, exp) = stateLock.withLock { (currentPin, pinExpiresAt) }
        guard now <= exp, entered == expected else {
            session.send(makeMessage(type: .pairResponse, accepted: false, reason: "Incorrect pair code"))
            return
        }
        let newToken = Self.generatePairToken()
        peerStore.save(TrustedPeerRecord(id: msg.deviceId, name: msg.deviceName, model: msg.deviceModel, pairToken: newToken))
        _ = rotatePairingPin()
        var resp = makeMessage(type: .pairResponse, accepted: true)
        resp.pairToken = newToken
        resp.adbSerial = localAdbSerial
        session.send(resp)
        promoteVerifiedSession(session, msg: msg)
    }

    private func handlePairResponse(_ msg: ContinuityWireMessage, on session: ContinuityTcpSession) {
        let sid = session.sessionId
        guard msg.accepted == true, let token = msg.pairToken, !token.isEmpty else {
            let err = ContinuityHostError.pairingRejected(msg.reason ?? "Incorrect pair code")
            pendingPairCompletions.removeValue(forKey: sid)?(.failure(err))
            return
        }
        peerStore.save(TrustedPeerRecord(id: msg.deviceId, name: msg.deviceName, model: msg.deviceModel, pairToken: token))
        let verified = promoteVerifiedSession(session, msg: msg)
        pendingPairCompletions.removeValue(forKey: sid)?(.success(verified))
    }

    @discardableResult
    func promoteVerifiedSession(_ session: ContinuityTcpSession, msg: ContinuityWireMessage) -> VerifiedConnectedPeer {
        session.isAuthenticated = true
        activeSessionId = session.sessionId
        recordDiscovered(msg: msg, on: session, isPaired: true)
        let verified = VerifiedConnectedPeer(
            id: msg.deviceId,
            name: msg.deviceName,
            model: msg.deviceModel,
            isUsb: session.isUsbTransport,
            batteryLevel: msg.batteryLevel ?? 100,
            isCharging: msg.isCharging ?? false,
            adbSerial: msg.adbSerial ?? (session.isUsbTransport ? localAdbSerial : nil),
            mediaTitle: msg.mediaTitle,
            mediaArtist: msg.mediaArtist,
            mediaPlaying: msg.mediaPlaying ?? false
        )
        publishConnectedPeer(verified)
        return verified
    }

    func recordDiscovered(msg: ContinuityWireMessage, on session: ContinuityTcpSession, isPaired: Bool) {
        let port = msg.listeningPort ?? Self.defaultAndroidPort
        let host: String
        if session.isUsbTransport {
            host = "127.0.0.1"
        } else if case .hostPort(let remoteHost, _) = session.connection?.currentPath?.remoteEndpoint {
            host = "\(remoteHost)".components(separatedBy: "%").first ?? msg.deviceName
        } else {
            host = discoveredById[msg.deviceId]?.host ?? msg.deviceName
        }
        discoveredById[msg.deviceId] = DiscoveredContinuityPeer(
            id: msg.deviceId, name: msg.deviceName, model: msg.deviceModel,
            host: host, port: port, isUsb: session.isUsbTransport, isPaired: isPaired
        )
        publishDiscoveredPeers()
    }

    func publishConnectedPeer(_ peer: VerifiedConnectedPeer?) {
        stateLock.withLock { self.connectedPeer = peer }
        onConnectedPeerChanged?(peer)
    }

    func publishDiscoveredPeers() {
        onDiscoveredPeersChanged?(snapshotDiscoveredPeers())
    }

    func clearActiveSessionIfMatching(_ sid: UUID) {
        guard activeSessionId == sid else { return }
        activeSessionId = nil
        publishConnectedPeer(nil)
    }

    func makeMessage(type: ContinuityWireMessage.Kind, accepted: Bool? = nil, reason: String? = nil) -> ContinuityWireMessage {
        let id = peerStore.localDeviceIdentity()
        return ContinuityWireMessage(
            type: type,
            deviceId: id.id,
            deviceName: id.name,
            deviceModel: "Mac",
            role: "mac",
            accepted: accepted,
            reason: reason,
            listeningPort: boundPort,
            timestampMs: Int64(Date().timeIntervalSince1970 * 1000)
        )
    }

    private static func generatePairToken() -> String {
        let key = SymmetricKey(size: .bits128)
        return key.withUnsafeBytes { bytes in
            bytes.map { String(format: "%02x", $0) }.joined()
        }
    }
}
