package dev.mirror.continuity.network

import java.io.BufferedReader
import java.io.BufferedWriter
import java.net.Socket
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Outbound socket dialing helpers for pairing, auto-reconnect hello, and unpaired USB probes.
 */
internal object ContinuitySessionConnector {
    @Volatile private var lastUnpairedUsbProbeMs: Long = 0L

    fun buildMessage(
        type: String,
        store: ContinuityPrefsStore?,
        batteryLevel: Int,
        isCharging: Boolean,
        listenPort: Int,
        reason: String? = null
    ): ContinuityWireMessage = ContinuityWireMessage(
        type = type,
        deviceId = store?.getOrCreateLocalDeviceId() ?: "android-unknown",
        deviceName = store?.getLocalDeviceName() ?: "Android",
        deviceModel = store?.getLocalDeviceModel() ?: "Android",
        role = "android",
        reason = reason,
        batteryLevel = batteryLevel,
        isCharging = isCharging,
        listeningPort = listenPort,
        timestampMs = System.currentTimeMillis()
    )

    suspend fun performPairOverCandidates(
        store: ContinuityPrefsStore,
        candidates: List<Triple<String, Int, Boolean>>,
        pinCode: String,
        makeMessage: (String, ContinuityPrefsStore, String?) -> ContinuityWireMessage,
        attachLoop: (Socket, BufferedWriter, BufferedReader, String, Int, Boolean, ContinuityPrefsStore, CompletableDeferred<Pair<Boolean, String?>>) -> Unit,
        onError: (String) -> Unit
    ) {
        var lastError: String? = null
        for ((host, port, viaUsb) in candidates) {
            val (socket, writer, reader) = ContinuitySocketTransport.connect(host, port, 2200) ?: continue
            val pairReq = makeMessage("pair_request", store, null).copy(code = pinCode)
            if (!ContinuitySocketTransport.sendLine(writer, pairReq)) {
                runCatching { socket.close() }
                continue
            }
            val deferred = CompletableDeferred<Pair<Boolean, String?>>()
            attachLoop(socket, writer, reader, host, port, viaUsb, store, deferred)
            val outcome = withTimeoutOrNull(7000L) { deferred.await() }
            if (outcome?.first == true) return
            lastError = outcome?.second ?: "No pairing reply from $host:$port"
            runCatching { socket.close() }
            if (outcome?.second?.contains("Incorrect", ignoreCase = true) == true) break
        }
        onError(lastError ?: "Could not connect to Mirror app on Mac")
    }

    suspend fun probeUsbHelloIfNeeded(
        throttleWhenKnown: Boolean,
        hasUsbSocketMac: Boolean,
        hasActiveProbeSocket: Boolean,
        host: String,
        port: Int,
        helloMsg: ContinuityWireMessage,
        onConnectFailed: () -> Unit,
        onConnected: (Socket, BufferedWriter, BufferedReader) -> Unit
    ) {
        if (throttleWhenKnown && hasUsbSocketMac && hasActiveProbeSocket) return
        val now = System.currentTimeMillis()
        if (throttleWhenKnown && now - lastUnpairedUsbProbeMs < 5000L) return
        lastUnpairedUsbProbeMs = now
        val connected = ContinuitySocketTransport.connect(host, port, 900)
        if (connected == null) {
            onConnectFailed()
            return
        }
        val (socket, writer, reader) = connected
        if (!ContinuitySocketTransport.sendLine(writer, helloMsg)) {
            runCatching { socket.close() }
            return
        }
        onConnected(socket, writer, reader)
    }

    suspend fun attemptAutoHello(
        store: ContinuityPrefsStore,
        host: String,
        port: Int,
        viaUsb: Boolean,
        helloMsg: ContinuityWireMessage,
        attachLoop: (Socket, BufferedWriter, BufferedReader, String, Int, Boolean, ContinuityPrefsStore, CompletableDeferred<Pair<Boolean, String?>>?) -> Unit
    ) {
        val (socket, writer, reader) = ContinuitySocketTransport.connect(host, port, 1000) ?: return
        if (!ContinuitySocketTransport.sendLine(writer, helloMsg)) {
            runCatching { socket.close() }
            return
        }
        attachLoop(socket, writer, reader, host, port, viaUsb, store, null)
    }
}
