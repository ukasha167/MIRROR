import Foundation
import Network

/// Manages macOS Mirror Continuity TCP server, Bonjour discovery/advertising, mutual pairing handshake, and keepalive presence.
public final class ContinuityHostServer: @unchecked Sendable {
    public static let defaultListenPort: UInt16 = 53318
    public static let defaultAndroidPort: UInt16 = 53319
    public static let serviceType = "_mirror-cont._tcp"

    public let peerStore: PairedPeerStore
    let queue = DispatchQueue(label: "dev.mirror.continuity.host", qos: .userInitiated)
    let stateLock = NSLock()

    private var listener: NWListener?
    var browser: NWBrowser?
    private var keepaliveTimer: DispatchSourceTimer?

    var listenPort: UInt16 = defaultListenPort
    var currentPin: String = ContinuityPairingCodec.generatePin()
    var pinExpiresAt: Int64 = Int64(Date().timeIntervalSince1970) + 600

    var sessions: [UUID: ContinuityTcpSession] = [:]
    var activeSessionId: UUID?
    var connectedPeer: VerifiedConnectedPeer?
    var discoveredById: [String: DiscoveredContinuityPeer] = [:]
    var bonjourEndpoints: [String: NWEndpoint] = [:]
    var pendingPairCompletions: [UUID: (Result<VerifiedConnectedPeer, Error>) -> Void] = [:]
    var localAdbSerial: String?
    private var usbAttachedForQr = false

    public var onConnectedPeerChanged: (@Sendable (VerifiedConnectedPeer?) -> Void)?
    public var onDiscoveredPeersChanged: (@Sendable ([DiscoveredContinuityPeer]) -> Void)?
    public var onRemoteMediaChanged: (@Sendable (String?, String?, Bool) -> Void)?
    public var onRemoteClipboardReceived: (@Sendable (String) -> Void)?

    public init(peerStore: PairedPeerStore = PairedPeerStore()) {
        self.peerStore = peerStore
    }

    deinit {
        stop()
    }

    public var boundPort: UInt16 {
        stateLock.withLock { listenPort }
    }

    public func currentPairingPin() -> String {
        stateLock.withLock {
            let now = Int64(Date().timeIntervalSince1970)
            if now >= pinExpiresAt {
                currentPin = ContinuityPairingCodec.generatePin()
                pinExpiresAt = now + 600
            }
            return currentPin
        }
    }

    @discardableResult
    public func rotatePairingPin() -> String {
        stateLock.withLock {
            currentPin = ContinuityPairingCodec.generatePin()
            pinExpiresAt = Int64(Date().timeIntervalSince1970) + 600
            return currentPin
        }
    }

    public func currentQrPayloadString() -> String {
        let identity = peerStore.localDeviceIdentity()
        let port = boundPort
        let pin = currentPairingPin()
        let (expiresAt, hasUsb) = stateLock.withLock { (pinExpiresAt, usbAttachedForQr) }
        var endpoints: [ContinuityEndpointCandidate] = []
        if hasUsb {
            endpoints.append(ContinuityEndpointCandidate(address: "127.0.0.1:\(port)", kind: .usb))
        }
        endpoints.append(contentsOf: LocalNetworkEnumerator.lanIPv4Addresses().map {
            ContinuityEndpointCandidate(address: "\($0):\(port)", kind: .lan)
        })
        let payload = ContinuityPairingPayload(
            serviceName: Self.serviceType,
            passcode: pin,
            deviceId: identity.id,
            deviceName: identity.name,
            fingerprint: identity.fingerprint,
            endpoints: endpoints,
            expiresAt: expiresAt
        )
        return ContinuityPairingCodec.encodeQR(payload)
    }

    public func setLocalAdbSerial(_ serial: String?) {
        stateLock.withLock { usbAttachedForQr = (serial != nil) }
        queue.async { [weak self] in
            guard let self else { return }
            self.localAdbSerial = serial
            if serial == nil {
                var removed = false
                for (id, peer) in self.discoveredById where peer.isUsb {
                    self.discoveredById.removeValue(forKey: id)
                    removed = true
                }
                if removed { self.publishDiscoveredPeers() }
            }
        }
    }

    public func start(preferredPort: UInt16 = defaultListenPort) {
        queue.async { [weak self] in
            guard let self, self.listener == nil else { return }
            self.startListener(preferredPort: preferredPort)
            self.startBonjourBrowser()
            self.startKeepaliveTimer()
        }
    }

    public func stop() {
        queue.sync {
            keepaliveTimer?.cancel()
            keepaliveTimer = nil
            browser?.cancel()
            browser = nil
            listener?.cancel()
            listener = nil
            for session in sessions.values { session.close() }
            sessions.removeAll()
            activeSessionId = nil
            connectedPeer = nil
        }
        onConnectedPeerChanged?(nil)
    }

    public func snapshotConnectedPeer() -> VerifiedConnectedPeer? {
        stateLock.withLock { connectedPeer }
    }

    public func snapshotDiscoveredPeers() -> [DiscoveredContinuityPeer] {
        stateLock.withLock {
            Array(discoveredById.values).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    /// Probes `127.0.0.1:<forwardedPort>` forwarded via `adb forward` to Android Continuity listener.
    public func probeUsbPeer(port: UInt16) {
        queue.async { [weak self] in
            guard let self,
                  self.snapshotConnectedPeer() == nil,
                  !self.sessions.values.contains(where: { $0.isUsbTransport }),
                  let nwPort = NWEndpoint.Port(rawValue: port) else { return }
            let conn = NWConnection(host: "127.0.0.1", port: nwPort, using: .tcp)
            self.attachOutgoingConnection(conn, isUsb: true)
        }
    }

    /// Initiates pairing from Mac to an Android peer by entering the Android app's 6-digit pair code.
    public func pairWithPhone(peerId: String?, manualAddress: String?, pinCode: String) async throws -> VerifiedConnectedPeer {
        let normalizedPin = ContinuityPairingCodec.normalizePin(pinCode)
        guard normalizedPin.count == 6 else {
            throw ContinuityPairingError.invalidPinFormat(expectedLength: 6, actual: pinCode)
        }

        return try await withCheckedThrowingContinuation { cont in
            queue.async { [weak self] in
                guard let self else {
                    cont.resume(throwing: ContinuityHostError.connectionFailed("Server stopped"))
                    return
                }
                if let peerId,
                   let existingSession = self.sessions.values.first(where: { $0.peerDeviceId == peerId && $0.isReady }) {
                    self.sendPairRequest(on: existingSession, pin: normalizedPin) { cont.resume(with: $0) }
                    return
                }
                do {
                    let (endpoint, isUsb) = try self.resolveTargetEndpoint(peerId: peerId, manualAddress: manualAddress)
                    let conn = NWConnection(to: endpoint, using: .tcp)
                    let session = ContinuityTcpSession(connection: conn, queue: self.queue, isUsbTransport: isUsb)
                    self.registerSessionHandlers(session)
                    self.sessions[session.sessionId] = session
                    session.start { [weak self, weak session] in
                        guard let self, let session else { return }
                        self.sendPairRequest(on: session, pin: normalizedPin) { cont.resume(with: $0) }
                    }
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    public func disconnectActiveSession() {
        queue.async { [weak self] in
            guard let self, let sid = self.activeSessionId, let session = self.sessions[sid] else { return }
            session.send(self.makeMessage(type: .bye, reason: "disconnected"))
            session.close()
            self.clearActiveSessionIfMatching(sid)
        }
    }

    public func unpair(deviceId: String) {
        peerStore.remove(id: deviceId)
        queue.async { [weak self] in
            guard let self else { return }
            if let sid = self.activeSessionId, let session = self.sessions[sid], session.peerDeviceId == deviceId {
                session.send(self.makeMessage(type: .bye, reason: "unpaired"))
                session.close()
                self.clearActiveSessionIfMatching(sid)
            }
            if var peer = self.discoveredById[deviceId] {
                peer.isPaired = false
                self.discoveredById[deviceId] = peer
                self.publishDiscoveredPeers()
            }
        }
    }

    public func sendClipboardText(_ text: String) {
        queue.async { [weak self] in
            guard let self, let sid = self.activeSessionId, let session = self.sessions[sid] else { return }
            var msg = self.makeMessage(type: .clipboardSync)
            msg.clipboardText = text
            session.send(msg)
        }
    }

    private func resolveTargetEndpoint(peerId: String?, manualAddress: String?) throws -> (NWEndpoint, Bool) {
        if let manualAddress {
            let trimmed = manualAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let parts = trimmed.split(separator: ":")
                let host = String(parts[0])
                let portNum = parts.count > 1 ? (UInt16(parts[1]) ?? Self.defaultAndroidPort) : Self.defaultAndroidPort
                guard let nwPort = NWEndpoint.Port(rawValue: portNum) else {
                    throw ContinuityHostError.invalidEndpoint(manualAddress)
                }
                return (.hostPort(host: NWEndpoint.Host(host), port: nwPort), host == "127.0.0.1")
            }
        }
        if let peerId, let peer = discoveredById[peerId] {
            if !peer.isUsb, let bonjourEp = bonjourEndpoints[peerId] {
                return (bonjourEp, false)
            }
            if let nwPort = NWEndpoint.Port(rawValue: peer.port) {
                return (.hostPort(host: NWEndpoint.Host(peer.host), port: nwPort), peer.isUsb)
            }
            throw ContinuityHostError.invalidEndpoint("\(peer.host):\(peer.port)")
        }
        throw ContinuityHostError.connectionFailed("Select a discovered phone or enter its IP address")
    }

    private func startListener(preferredPort: UInt16) {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let nwListener: NWListener
        if let port = NWEndpoint.Port(rawValue: preferredPort), let bound = try? NWListener(using: params, on: port) {
            nwListener = bound
        } else if let anyBound = try? NWListener(using: params, on: .any) {
            nwListener = anyBound
        } else {
            return
        }

        let identity = peerStore.localDeviceIdentity()
        var txt = NWTXTRecord()
        txt["id"] = identity.id
        txt["name"] = identity.name
        txt["role"] = "mac"
        nwListener.service = NWListener.Service(name: identity.name, type: Self.serviceType, txtRecord: txt)

        nwListener.stateUpdateHandler = { [weak self, weak nwListener] state in
            guard let self, let nwListener else { return }
            if case .ready = state, let port = nwListener.port?.rawValue {
                self.stateLock.withLock { self.listenPort = port }
            }
        }
        nwListener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            let isUsb: Bool
            if case .hostPort(let host, _) = conn.endpoint {
                isUsb = "\(host)".contains("127.0.0.1") || "\(host)".contains("::1")
            } else {
                isUsb = false
            }
            let session = ContinuityTcpSession(connection: conn, queue: self.queue, isUsbTransport: isUsb)
            self.registerSessionHandlers(session)
            self.sessions[session.sessionId] = session
            session.start()
        }
        self.listener = nwListener
        nwListener.start(queue: queue)
    }

    func registerSessionHandlers(_ session: ContinuityTcpSession) {
        let sid = session.sessionId
        session.onMessage = { [weak self, weak session] msg in
            guard let self, let session else { return }
            self.handleMessage(msg, on: session)
        }
        session.onClosed = { [weak self] in
            guard let self else { return }
            self.sessions.removeValue(forKey: sid)
            if let pending = self.pendingPairCompletions.removeValue(forKey: sid) {
                pending(.failure(ContinuityHostError.connectionFailed("Peer disconnected during pairing")))
            }
            self.clearActiveSessionIfMatching(sid)
        }
    }

    private func sendPairRequest(on session: ContinuityTcpSession, pin: String, completion: @escaping (Result<VerifiedConnectedPeer, Error>) -> Void) {
        let sid = session.sessionId
        pendingPairCompletions[sid] = completion
        var req = makeMessage(type: .pairRequest)
        req.code = pin
        req.adbSerial = localAdbSerial
        session.send(req)

        queue.asyncAfter(deadline: .now() + 8.0) { [weak self] in
            guard let self, let pending = self.pendingPairCompletions.removeValue(forKey: sid) else { return }
            pending(.failure(ContinuityHostError.timeout("No pairing response from Android app")))
        }
    }

    private func startKeepaliveTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 3.0, repeating: 3.0)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = Date()
            if let sid = self.activeSessionId, let session = self.sessions[sid] {
                if now.timeIntervalSince(session.lastActivityAt) > 9.0 {
                    session.close()
                    self.sessions.removeValue(forKey: sid)
                    self.clearActiveSessionIfMatching(sid)
                } else {
                    session.send(self.makeMessage(type: .ping))
                }
            }
            for session in self.sessions.values where !session.isAuthenticated && session.isUsbTransport && session.isReady {
                if now.timeIntervalSince(session.lastActivityAt) > 12.0 {
                    session.send(self.makeMessage(type: .ping))
                }
            }
        }
        timer.resume()
        keepaliveTimer = timer
    }
}
