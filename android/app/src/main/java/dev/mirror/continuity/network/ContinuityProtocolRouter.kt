package dev.mirror.continuity.network

import dev.mirror.continuity.pairing.ContinuityPairingCodec
import java.io.BufferedWriter
import java.net.Socket

sealed class ContinuityLinkState {
    data object Disconnected : ContinuityLinkState()
    data class Connected(
        val macId: String,
        val macName: String,
        val viaUsb: Boolean
    ) : ContinuityLinkState()
}

sealed class PairingAttemptState {
    data object Idle : PairingAttemptState()
    data object Pairing : PairingAttemptState()
    data class Paired(val macName: String) : PairingAttemptState()
    data class Error(val message: String) : PairingAttemptState()
}

internal data class SessionRouterCallbacks(
    val onPromoteConnected: (Socket, BufferedWriter, String, Int, String, String, Boolean) -> Unit,
    val onCloseSession: () -> Unit,
    val onTrustedMacUpdated: (TrustedMacPeer?) -> Unit,
    val onMacDiscovered: (DiscoveredMacPeer) -> Unit,
    val onPairOutcome: (Boolean, String?, String?) -> Unit,
    val rotateLocalCode: () -> Unit,
    val getLocalPairCode: () -> String,
    val makeMessage: (String, ContinuityPrefsStore, String?) -> ContinuityWireMessage
)

/**
 * Pure protocol state transitions for inbound Continuity control messages on Android.
 */
internal object ContinuityProtocolRouter {
    fun handleMessage(
        msg: ContinuityWireMessage,
        socket: Socket,
        writer: BufferedWriter,
        remoteHost: String,
        remotePort: Int,
        viaUsb: Boolean,
        store: ContinuityPrefsStore,
        callbacks: SessionRouterCallbacks
    ) {
        when (msg.type) {
            "hello" -> {
                val peerHost = if (viaUsb) "127.0.0.1" else remoteHost
                val peerPort = msg.listeningPort ?: ContinuityLinkManager.DEFAULT_MAC_PORT
                callbacks.onMacDiscovered(DiscoveredMacPeer(msg.deviceId, msg.deviceName, peerHost, peerPort, viaUsb))
                val stored = store.getTrustedMac()
                if (stored != null && stored.id == msg.deviceId && !msg.pairToken.isNullOrBlank() && msg.pairToken == stored.pairToken) {
                    ContinuitySocketTransport.sendLine(writer, callbacks.makeMessage("hello_ack", store, null).copy(accepted = true, pairToken = stored.pairToken))
                    callbacks.onPromoteConnected(socket, writer, remoteHost, remotePort, msg.deviceId, msg.deviceName, viaUsb)
                } else {
                    ContinuitySocketTransport.sendLine(writer, callbacks.makeMessage("hello_ack", store, "Pairing required").copy(accepted = false))
                }
            }
            "hello_ack" -> {
                val peerHost = if (viaUsb) "127.0.0.1" else remoteHost
                val peerPort = msg.listeningPort ?: ContinuityLinkManager.DEFAULT_MAC_PORT
                callbacks.onMacDiscovered(DiscoveredMacPeer(msg.deviceId, msg.deviceName, peerHost, peerPort, viaUsb))
                val stored = store.getTrustedMac()
                if (msg.accepted == true && stored != null && msg.pairToken == stored.pairToken) {
                    callbacks.onPromoteConnected(socket, writer, remoteHost, remotePort, msg.deviceId, msg.deviceName, viaUsb)
                }
            }
            "pair_request" -> {
                if (ContinuityPairingCodec.normalizePin(msg.code.orEmpty()) == callbacks.getLocalPairCode()) {
                    val token = store.generatePairToken()
                    val peer = TrustedMacPeer(id = msg.deviceId, name = msg.deviceName, pairToken = token)
                    store.saveTrustedMac(peer)
                    callbacks.onTrustedMacUpdated(peer)
                    callbacks.rotateLocalCode()
                    ContinuitySocketTransport.sendLine(writer, callbacks.makeMessage("pair_response", store, null).copy(accepted = true, pairToken = token))
                    callbacks.onPromoteConnected(socket, writer, remoteHost, remotePort, msg.deviceId, msg.deviceName, viaUsb)
                    callbacks.onPairOutcome(true, msg.deviceName, null)
                } else {
                    ContinuitySocketTransport.sendLine(writer, callbacks.makeMessage("pair_response", store, "Incorrect pair code").copy(accepted = false))
                }
            }
            "pair_response" -> {
                val token = msg.pairToken.orEmpty()
                if (msg.accepted == true && token.isNotEmpty()) {
                    val peer = TrustedMacPeer(id = msg.deviceId, name = msg.deviceName, pairToken = token)
                    store.saveTrustedMac(peer)
                    callbacks.onTrustedMacUpdated(peer)
                    callbacks.onPromoteConnected(socket, writer, remoteHost, remotePort, msg.deviceId, msg.deviceName, viaUsb)
                    callbacks.onPairOutcome(true, msg.deviceName, null)
                } else {
                    callbacks.onPairOutcome(false, null, msg.reason ?: "Pairing rejected")
                }
            }
            "ping" -> ContinuitySocketTransport.sendLine(writer, callbacks.makeMessage("pong", store, null))
            "pong" -> Unit
            "bye" -> {
                if (msg.reason == "unpaired") {
                    store.clearTrustedMac()
                    callbacks.onTrustedMacUpdated(null)
                }
                callbacks.onCloseSession()
                runCatching { socket.close() }
            }
        }
    }

    fun buildPairCandidates(
        manualAddress: String?,
        selectedMac: DiscoveredMacPeer?,
        discoveredMacs: List<DiscoveredMacPeer>,
        isUsbAttached: Boolean,
        defaultPort: Int
    ): List<Triple<String, Int, Boolean>> {
        val candidates = mutableListOf<Triple<String, Int, Boolean>>()
        val manual = manualAddress?.trim().orEmpty()
        if (manual.isNotEmpty()) {
            val parts = manual.split(":")
            val host = parts[0].trim()
            val port = parts.getOrNull(1)?.toIntOrNull() ?: defaultPort
            addCandidate(candidates, host, port, host == "127.0.0.1")
        }
        if (isUsbAttached || selectedMac?.viaUsb == true) {
            addCandidate(candidates, "127.0.0.1", defaultPort, true)
        }
        selectedMac?.let { addCandidate(candidates, it.host, it.port, it.viaUsb || it.host == "127.0.0.1") }
        discoveredMacs.forEach { mac ->
            addCandidate(candidates, mac.host, mac.port, mac.viaUsb || mac.host == "127.0.0.1")
        }
        // Always probe USB adb-reverse loopback as fast fallback (<5ms if unused)
        addCandidate(candidates, "127.0.0.1", defaultPort, true)
        return candidates
    }

    fun buildQrCandidates(
        endpoints: List<dev.mirror.continuity.pairing.ContinuityEndpoint>,
        isUsbAttached: Boolean,
        defaultPort: Int
    ): List<Triple<String, Int, Boolean>> {
        val candidates = mutableListOf<Triple<String, Int, Boolean>>()
        if (isUsbAttached) {
            val usbPort = endpoints.firstOrNull { it.kind == "usb" }?.port ?: defaultPort
            addCandidate(candidates, "127.0.0.1", usbPort, true)
        }
        endpoints.forEach { ep ->
            val host = ep.host.trim()
            val port = ep.port ?: defaultPort
            addCandidate(candidates, host, port, ep.kind == "usb" || host == "127.0.0.1")
        }
        addCandidate(candidates, "127.0.0.1", defaultPort, true)
        return candidates
    }

    private fun addCandidate(
        candidates: MutableList<Triple<String, Int, Boolean>>,
        host: String,
        port: Int,
        viaUsb: Boolean
    ) {
        if (host.isBlank()) return
        if (candidates.none { it.first == host && it.second == port }) {
            candidates += Triple(host, port, viaUsb)
        }
    }

    fun mergeDiscoveredMacs(
        socketMacs: List<DiscoveredMacPeer>,
        nsdMacs: List<DiscoveredMacPeer>
    ): List<DiscoveredMacPeer> {
        val byId = LinkedHashMap<String, DiscoveredMacPeer>()
        socketMacs.forEach { mac ->
            val prev = byId[mac.id]
            if (prev == null || (!prev.viaUsb && mac.viaUsb)) byId[mac.id] = mac
        }
        nsdMacs.forEach { mac ->
            val prev = byId[mac.id]
            if (prev == null || (!prev.viaUsb && mac.viaUsb)) byId[mac.id] = mac
        }
        return byId.values.sortedByDescending { it.viaUsb }
    }
}
