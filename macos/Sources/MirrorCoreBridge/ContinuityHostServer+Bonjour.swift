import Foundation
import Network

extension ContinuityHostServer {
    func startBonjourBrowser() {
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(type: Self.serviceType, domain: nil)
        let nwBrowser = NWBrowser(for: descriptor, using: .tcp)
        nwBrowser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            let myId = self.peerStore.localDeviceIdentity().id
            var seenIds = Set<String>()
            for result in results {
                guard case .service(let svcName, _, _, _) = result.endpoint else { continue }
                var peerId = svcName
                var peerName = svcName
                var peerModel = "Android Device"
                var role = ""
                if case .bonjour(let txt) = result.metadata {
                    if let r = txt["role"] { role = r }
                    if let id = txt["id"], !id.isEmpty { peerId = id }
                    if let name = txt["name"], !name.isEmpty { peerName = name }
                    if let model = txt["model"], !model.isEmpty { peerModel = model }
                }
                guard peerId != myId, role != "mac" else { continue }
                seenIds.insert(peerId)
                self.bonjourEndpoints[peerId] = result.endpoint
                let isPaired = self.peerStore.peer(id: peerId) != nil
                self.discoveredById[peerId] = DiscoveredContinuityPeer(
                    id: peerId, name: peerName, model: peerModel,
                    host: svcName, port: Self.defaultAndroidPort, isUsb: false, isPaired: isPaired
                )
                if isPaired && self.snapshotConnectedPeer() == nil && !self.sessions.values.contains(where: { $0.peerDeviceId == peerId }) {
                    self.attachOutgoingConnection(NWConnection(to: result.endpoint, using: .tcp), isUsb: false, targetPeerId: peerId)
                }
            }
            for existingId in Array(self.discoveredById.keys) where !seenIds.contains(existingId) && !(self.discoveredById[existingId]?.isUsb ?? false) {
                self.discoveredById.removeValue(forKey: existingId)
                self.bonjourEndpoints.removeValue(forKey: existingId)
            }
            self.publishDiscoveredPeers()
        }
        self.browser = nwBrowser
        nwBrowser.start(queue: queue)
    }

    func attachOutgoingConnection(_ conn: NWConnection, isUsb: Bool, targetPeerId: String? = nil) {
        let session = ContinuityTcpSession(connection: conn, queue: queue, isUsbTransport: isUsb)
        registerSessionHandlers(session)
        sessions[session.sessionId] = session
        session.start { [weak self, weak session] in
            guard let self, let session else { return }
            var hello = self.makeMessage(type: .hello)
            hello.pairToken = (targetPeerId.flatMap { self.peerStore.peer(id: $0)?.pairToken }) ?? self.peerStore.allPeers().first?.pairToken
            hello.adbSerial = self.localAdbSerial
            session.send(hello)
        }
    }
}
