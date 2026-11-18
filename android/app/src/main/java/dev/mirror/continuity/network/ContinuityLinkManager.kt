package dev.mirror.continuity.network

import android.content.Context
import dev.mirror.continuity.PresenceWakeService
import dev.mirror.continuity.pairing.ContinuityPairingCodec
import java.io.BufferedReader
import java.io.BufferedWriter
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * Manages mutual TCP/NSD/USB-tunnel Continuity handshake, dual-direction pairing, and keepalive state.
 * A USB cable or Bluetooth event alone NEVER sets [isConnectedFlow] to true; both apps must be running
 * and complete an authenticated token or 6-digit pair-code handshake.
 */
object ContinuityLinkManager {
    const val DEFAULT_MAC_PORT = 53318
    const val DEFAULT_ANDROID_PORT = 53319

    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private val started = AtomicBoolean(false)

    private var prefsStore: ContinuityPrefsStore? = null
    private val discoveryTracker = ContinuityDiscoveryTracker()
    private var serverSocket: ServerSocket? = null
    private var listenPort: Int = DEFAULT_ANDROID_PORT

    @Volatile private var activeSocket: Socket? = null
    @Volatile private var activeWriter: BufferedWriter? = null
    @Volatile private var unpairedProbeSocket: Socket? = null
    @Volatile private var pendingPairResult: CompletableDeferred<Pair<Boolean, String?>>? = null
    @Volatile private var lastBatteryLevel: Int = 100
    @Volatile private var lastIsCharging: Boolean = false

    private var autoReconnectJob: Job? = null
    private var keepaliveJob: Job? = null

    private val _connectionState = MutableStateFlow<ContinuityLinkState>(ContinuityLinkState.Disconnected)
    val connectionState: StateFlow<ContinuityLinkState> = _connectionState.asStateFlow()

    private val _isConnectedFlow = MutableStateFlow(false)
    val isConnectedFlow: StateFlow<Boolean> = _isConnectedFlow.asStateFlow()

    val isUsbCableAttachedFlow: StateFlow<Boolean> = discoveryTracker.isUsbCableAttachedFlow

    private val _localPairCodeFlow = MutableStateFlow(ContinuityPairingCodec.generatePin())
    val localPairCodeFlow: StateFlow<String> = _localPairCodeFlow.asStateFlow()

    val discoveredMacsFlow: StateFlow<List<DiscoveredMacPeer>> = discoveryTracker.discoveredMacsFlow

    private val _pairingStateFlow = MutableStateFlow<PairingAttemptState>(PairingAttemptState.Idle)
    val pairingStateFlow: StateFlow<PairingAttemptState> = _pairingStateFlow.asStateFlow()

    private val _trustedMacFlow = MutableStateFlow<TrustedMacPeer?>(null)
    val trustedMacFlow: StateFlow<TrustedMacPeer?> = _trustedMacFlow.asStateFlow()

    fun ensureStarted(context: Context) {
        val store = prefsStore ?: ContinuityPrefsStore(context.applicationContext).also { prefsStore = it }
        _trustedMacFlow.value = store.getTrustedMac()
        if (!started.compareAndSet(false, true)) return

        scope.launch {
            val startedServer = ContinuitySocketTransport.startServerSocket(DEFAULT_ANDROID_PORT, scope) { client, writer, reader, host, port, viaUsb ->
                attachSessionLoop(client, writer, reader, host, port, viaUsb, store)
            }
            if (startedServer != null) {
                serverSocket = startedServer.first
                listenPort = startedServer.second
            }

            discoveryTracker.startOrRestartNsd(context.applicationContext, store, listenPort) { mac ->
                if (!_isConnectedFlow.value) scope.launch { attemptAutoHello(mac.host, mac.port, viaUsb = false) }
            }
        }

        autoReconnectJob = scope.launch {
            while (isActive) {
                if (!_isConnectedFlow.value) {
                    if (prefsStore?.getTrustedMac() != null) {
                        if (isUsbCableAttachedFlow.value) attemptAutoHello("127.0.0.1", DEFAULT_MAC_PORT, viaUsb = true)
                        discoveredMacsFlow.value.firstOrNull()?.let { mac ->
                            if (!_isConnectedFlow.value) attemptAutoHello(mac.host, mac.port, viaUsb = mac.viaUsb)
                        }
                    } else if (isUsbCableAttachedFlow.value) {
                        probeUnpairedUsbHello(throttleWhenKnown = true)
                    }
                }
                delay(2500L)
            }
        }
    }

    fun restartDiscovery(context: Context) {
        val store = prefsStore ?: ContinuityPrefsStore(context.applicationContext).also { prefsStore = it }
        scope.launch {
            discoveryTracker.startOrRestartNsd(context.applicationContext, store, listenPort) { mac ->
                if (!_isConnectedFlow.value) scope.launch { attemptAutoHello(mac.host, mac.port, viaUsb = false) }
            }
        }
    }

    fun updateUsbDataAttached(attached: Boolean) {
        updateUsbAttachedState(dataAttached = attached, powerPlugged = null)
    }

    fun updatePowerAndUsbState(isUsbPlugged: Boolean, batteryLevel: Int, isCharging: Boolean) {
        lastBatteryLevel = batteryLevel
        lastIsCharging = isCharging
        updateUsbAttachedState(dataAttached = null, powerPlugged = isUsbPlugged)
        if (_isConnectedFlow.value) {
            activeWriter?.let { w ->
                scope.launch {
                    ContinuitySocketTransport.sendLine(w, makeMessage("status_update").copy(batteryLevel = batteryLevel, isCharging = isCharging))
                }
            }
        }
    }

    private fun updateUsbAttachedState(dataAttached: Boolean?, powerPlugged: Boolean?) {
        discoveryTracker.updateUsbState(dataAttached, powerPlugged) {
            if (!_isConnectedFlow.value) {
                scope.launch {
                    if (prefsStore?.getTrustedMac() != null) attemptAutoHello("127.0.0.1", DEFAULT_MAC_PORT, viaUsb = true)
                    else probeUnpairedUsbHello(throttleWhenKnown = false)
                }
            }
        }
        if (!isUsbCableAttachedFlow.value) {
            runCatching { unpairedProbeSocket?.close() }
            unpairedProbeSocket = null
        }
    }

    fun rotateLocalPairCode() {
        _localPairCodeFlow.value = ContinuityPairingCodec.generatePin()
    }

    fun clearPairingError() {
        if (_pairingStateFlow.value is PairingAttemptState.Error) {
            _pairingStateFlow.value = PairingAttemptState.Idle
        }
    }

    fun pairWithQr(rawQr: String) {
        val store = prefsStore ?: return
        _pairingStateFlow.value = PairingAttemptState.Pairing
        scope.launch {
            val payload = try {
                ContinuityPairingCodec.decodeQr(rawQr)
            } catch (e: Exception) {
                _pairingStateFlow.value = PairingAttemptState.Error(e.message ?: "Invalid QR code")
                return@launch
            }
            val candidates = ContinuityProtocolRouter.buildQrCandidates(
                endpoints = payload.endpoints,
                isUsbAttached = isUsbCableAttachedFlow.value,
                defaultPort = DEFAULT_MAC_PORT
            )
            if (candidates.isEmpty()) {
                _pairingStateFlow.value = PairingAttemptState.Error("QR has no reachable Mac address; check Wi-Fi or USB")
                return@launch
            }
            performPairOverCandidates(store, candidates, payload.passcode)
        }
    }

    fun pairWithMacCode(selectedMac: DiscoveredMacPeer?, manualAddress: String?, code: String) {
        val store = prefsStore ?: return
        val normalized = ContinuityPairingCodec.normalizePin(code)
        if (normalized.length != 6) {
            _pairingStateFlow.value = PairingAttemptState.Error("Enter the 6-digit code shown on your Mac")
            return
        }
        _pairingStateFlow.value = PairingAttemptState.Pairing
        scope.launch {
            val candidates = ContinuityProtocolRouter.buildPairCandidates(
                manualAddress = manualAddress,
                selectedMac = selectedMac,
                discoveredMacs = discoveredMacsFlow.value,
                isUsbAttached = isUsbCableAttachedFlow.value,
                defaultPort = DEFAULT_MAC_PORT
            )

            if (candidates.isEmpty()) {
                _pairingStateFlow.value = PairingAttemptState.Error("No Mac found. Open Mirror on Mac or enter its IP.")
                return@launch
            }
            performPairOverCandidates(store, candidates, normalized)
        }
    }

    fun unpairMac() {
        scope.launch {
            activeWriter?.let { ContinuitySocketTransport.sendLine(it, makeMessage("bye", reason = "unpaired")) }
            prefsStore?.clearTrustedMac()
            _trustedMacFlow.value = null
            _pairingStateFlow.value = PairingAttemptState.Idle
            closeActiveSession()
        }
    }

    fun triggerReconnectAttempt() {
        scope.launch {
            if (_isConnectedFlow.value || prefsStore?.getTrustedMac() == null) return@launch
            if (isUsbCableAttachedFlow.value) attemptAutoHello("127.0.0.1", DEFAULT_MAC_PORT, viaUsb = true)
            discoveredMacsFlow.value.firstOrNull()?.let { mac ->
                attemptAutoHello(mac.host, mac.port, viaUsb = mac.viaUsb)
            }
        }
    }

    private suspend fun performPairOverCandidates(store: ContinuityPrefsStore, candidates: List<Triple<String, Int, Boolean>>, pinCode: String) {
        ContinuitySessionConnector.performPairOverCandidates(
            store = store, candidates = candidates, pinCode = pinCode,
            makeMessage = { type, s, reason -> makeMessage(type, s, reason) },
            attachLoop = { sock, w, r, h, p, usb, s, deferred ->
                pendingPairResult = deferred
                attachSessionLoop(sock, w, r, h, p, usb, s, deferred)
            },
            onError = { err -> _pairingStateFlow.value = PairingAttemptState.Error(err) }
        )
        pendingPairResult = null
    }

    private suspend fun probeUnpairedUsbHello(throttleWhenKnown: Boolean) {
        val store = prefsStore ?: return
        if (_isConnectedFlow.value || store.getTrustedMac() != null) return
        ContinuitySessionConnector.probeUsbHelloIfNeeded(
            throttleWhenKnown = throttleWhenKnown,
            hasUsbSocketMac = discoveryTracker.hasUsbSocketMac(),
            hasActiveProbeSocket = unpairedProbeSocket != null,
            host = "127.0.0.1", port = DEFAULT_MAC_PORT, helloMsg = makeMessage("hello", store),
            onConnectFailed = { discoveryTracker.clearUsbSocketMacs() },
            onConnected = { socket, writer, reader ->
                val oldProbe = unpairedProbeSocket
                unpairedProbeSocket = socket
                if (oldProbe != null && oldProbe !== socket && oldProbe !== activeSocket) runCatching { oldProbe.close() }
                attachSessionLoop(socket, writer, reader, "127.0.0.1", DEFAULT_MAC_PORT, true, store)
            }
        )
    }

    private suspend fun attemptAutoHello(host: String, port: Int, viaUsb: Boolean) {
        val store = prefsStore ?: return
        val trusted = store.getTrustedMac() ?: return
        if (_isConnectedFlow.value) return
        ContinuitySessionConnector.attemptAutoHello(
            store, host, port, viaUsb, makeMessage("hello", store).copy(pairToken = trusted.pairToken)
        ) { sock, w, r, h, p, usb, s, d -> attachSessionLoop(sock, w, r, h, p, usb, s, d) }
    }

    private fun attachSessionLoop(
        socket: Socket, writer: BufferedWriter, reader: BufferedReader,
        remoteHost: String, remotePort: Int, viaUsb: Boolean, store: ContinuityPrefsStore,
        pairDeferred: CompletableDeferred<Pair<Boolean, String?>>? = null
    ) {
        var sessionPeerId: String? = null
        val routerCallbacks = SessionRouterCallbacks(
            onPromoteConnected = { sock, w, h, p, macId, macName, usb -> promoteVerifiedConnection(sock, w, h, p, macId, macName, usb) },
            onCloseSession = { closeActiveSession() },
            onTrustedMacUpdated = { peer -> _trustedMacFlow.value = peer },
            onMacDiscovered = { mac -> sessionPeerId = mac.id; discoveryTracker.upsertSocketMac(mac) },
            onPairOutcome = { accepted, macName, err ->
                val target = pairDeferred ?: pendingPairResult
                if (accepted && macName != null) { _pairingStateFlow.value = PairingAttemptState.Paired(macName); target?.complete(true to null) }
                else target?.complete(false to err)
            },
            rotateLocalCode = { rotateLocalPairCode() },
            getLocalPairCode = { _localPairCodeFlow.value },
            makeMessage = { type, s, reason -> makeMessage(type, s, reason) }
        )
        ContinuitySocketTransport.runReadLoop(
            socket = socket, reader = reader, scope = scope,
            onMessage = { msg -> ContinuityProtocolRouter.handleMessage(msg, socket, writer, remoteHost, remotePort, viaUsb, store, routerCallbacks) },
            onClosed = {
                pairDeferred?.complete(false to "Connection closed")
                if (unpairedProbeSocket === socket) {
                    unpairedProbeSocket = null
                    sessionPeerId?.let { id -> discoveryTracker.removeSocketPeer(id, viaUsb) }
                }
                if (activeSocket === socket) closeActiveSession()
            }
        )
    }

    private fun promoteVerifiedConnection(
        socket: Socket, writer: BufferedWriter, host: String, port: Int,
        macId: String, macName: String, viaUsb: Boolean
    ) {
        if (unpairedProbeSocket === socket) unpairedProbeSocket = null
        else unpairedProbeSocket?.let { runCatching { it.close() }; unpairedProbeSocket = null }
        if (activeSocket != null && activeSocket !== socket) runCatching { activeSocket?.close() }
        activeSocket = socket
        activeWriter = writer
        _connectionState.value = ContinuityLinkState.Connected(macId = macId, macName = macName, viaUsb = viaUsb)
        _isConnectedFlow.value = true
        PresenceWakeService.updateMutualConnectionState(connected = true, resolvedHost = host to port)
        keepaliveJob?.cancel()
        keepaliveJob = scope.launch {
            while (isActive && _isConnectedFlow.value) {
                delay(3500L)
                val w = activeWriter ?: break
                if (!ContinuitySocketTransport.sendLine(w, makeMessage("ping"))) {
                    closeActiveSession()
                    break
                }
            }
        }
    }

    private fun closeActiveSession() {
        keepaliveJob?.cancel()
        keepaliveJob = null
        val old = activeSocket
        activeSocket = null
        activeWriter = null
        runCatching { old?.close() }
        _connectionState.value = ContinuityLinkState.Disconnected
        _isConnectedFlow.value = false
        PresenceWakeService.updateMutualConnectionState(connected = false, resolvedHost = null)
    }

    private fun makeMessage(type: String, store: ContinuityPrefsStore? = prefsStore, reason: String? = null): ContinuityWireMessage =
        ContinuitySessionConnector.buildMessage(type, store, lastBatteryLevel, lastIsCharging, listenPort, reason)
}
