package dev.mirror.continuity.network

import android.util.Log
import java.io.BufferedReader
import java.io.BufferedWriter
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * Low-level NDJSON socket server, client connector, and line reader helpers for [ContinuityLinkManager].
 */
internal object ContinuitySocketTransport {
    private const val TAG = "ContinuitySocketTx"

    fun startServerSocket(
        preferredPort: Int,
        scope: CoroutineScope,
        onAccepted: (Socket, BufferedWriter, BufferedReader, String, Int, Boolean) -> Unit
    ): Pair<ServerSocket, Int>? {
        val srv = runCatching { ServerSocket(preferredPort) }.getOrNull()
            ?: runCatching { ServerSocket(0) }.getOrNull()
            ?: return null
        val port = srv.localPort

        scope.launch(Dispatchers.IO) {
            while (isActive && !srv.isClosed) {
                val client = runCatching { srv.accept() }.getOrNull() ?: break
                runCatching { client.soTimeout = 45_000 }
                val viaUsb = client.inetAddress?.isLoopbackAddress == true
                val writer = BufferedWriter(OutputStreamWriter(client.getOutputStream(), Charsets.UTF_8))
                val reader = BufferedReader(InputStreamReader(client.getInputStream(), Charsets.UTF_8))
                val remoteHost = client.inetAddress?.hostAddress ?: "127.0.0.1"
                onAccepted(client, writer, reader, remoteHost, client.port, viaUsb)
            }
        }
        return srv to port
    }

    fun connect(host: String, port: Int, connectTimeoutMs: Int): Triple<Socket, BufferedWriter, BufferedReader>? {
        return runCatching {
            val socket = Socket()
            socket.connect(InetSocketAddress(host, port), connectTimeoutMs)
            socket.soTimeout = 45_000
            val writer = BufferedWriter(OutputStreamWriter(socket.getOutputStream(), Charsets.UTF_8))
            val reader = BufferedReader(InputStreamReader(socket.getInputStream(), Charsets.UTF_8))
            Triple(socket, writer, reader)
        }.getOrNull()
    }

    fun sendLine(writer: BufferedWriter, message: ContinuityWireMessage): Boolean {
        return runCatching {
            synchronized(writer) {
                writer.write(message.toJsonLine() + "\n")
                writer.flush()
            }
        }.isSuccess
    }

    fun runReadLoop(
        socket: Socket,
        reader: BufferedReader,
        scope: CoroutineScope,
        onMessage: (ContinuityWireMessage) -> Unit,
        onClosed: () -> Unit
    ) {
        scope.launch(Dispatchers.IO) {
            try {
                while (isActive && !socket.isClosed) {
                    val line = reader.readLine() ?: break
                    val msg = ContinuityWireMessage.fromJsonLine(line) ?: continue
                    if (msg.role != "mac" && msg.type !in setOf("ping", "pong", "bye")) continue
                    onMessage(msg)
                }
            } catch (e: Exception) {
                Log.d(TAG, "Continuity socket closed: ${e.message}")
            } finally {
                onClosed()
                runCatching { socket.close() }
            }
        }
    }
}
