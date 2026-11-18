package dev.mirror.continuity.pairing

import java.security.SecureRandom

data class ContinuityEndpoint(
    val address: String,
    val kind: String = "lan"
) {
    val host: String
        get() {
            val idx = address.lastIndexOf(':')
            return if (idx > 0) address.substring(0, idx) else address
        }

    val port: Int?
        get() {
            val idx = address.lastIndexOf(':')
            if (idx <= 0 || idx >= address.length - 1) return null
            return address.substring(idx + 1).toIntOrNull()
        }
}

data class ContinuityPairingPayload(
    val serviceName: String,
    val passcode: String,
    val deviceId: String,
    val deviceName: String,
    val fingerprint: String,
    val endpoints: List<ContinuityEndpoint>,
    val expiresAt: Long
)

class ContinuityPairingException(message: String) : IllegalArgumentException(message)

/**
 * QR URI codec and 6-digit PIN helper matching macOS `ContinuityPairingCodec`
 * and Rust `ContinuityPairingQr` (`WIFI:T:ADB;S:<svc>;P:<pass>;ID:<id>;NAME:<name>;FP:<fp>;EP:<eps>;EXP:<ts>;;`).
 */
object ContinuityPairingCodec {
    private val random = SecureRandom()

    fun generatePin(): String {
        val value = random.nextInt(1_000_000)
        return value.toString().padStart(6, '0')
    }

    fun normalizePin(input: String): String {
        val builder = StringBuilder(6)
        for (ch in input) {
            if (ch.isDigit()) {
                builder.append(ch)
                if (builder.length == 6) break
            }
        }
        return builder.toString()
    }

    fun formatPin(pin: String): String {
        val digits = normalizePin(pin)
        return if (digits.length == 6) "${digits.substring(0, 3)} ${digits.substring(3)}" else digits
    }

    fun encodeQr(payload: ContinuityPairingPayload): String {
        val epString = payload.endpoints.joinToString(",") { "${escape(it.address)}@${it.kind}" }
        return listOf(
            "WIFI:T:ADB",
            "S:${escape(payload.serviceName)}",
            "P:${escape(payload.passcode)}",
            "ID:${escape(payload.deviceId)}",
            "NAME:${escape(payload.deviceName)}",
            "FP:${escape(payload.fingerprint)}",
            "EP:$epString",
            "EXP:${payload.expiresAt}",
            ";"
        ).joinToString(";")
    }

    fun decodeQr(
        raw: String,
        validateExpiry: Boolean = true,
        nowEpochSeconds: Long = System.currentTimeMillis() / 1000L
    ): ContinuityPairingPayload {
        val trimmed = raw.trim()
        if (!trimmed.startsWith("WIFI:")) {
            throw ContinuityPairingException("QR code is not a Mirror Continuity pairing code")
        }

        val tokens = splitUnescaped(trimmed.removePrefix("WIFI:"), ';')
        val fields = mutableMapOf<String, String>()
        for (token in tokens) {
            if (token.isEmpty()) continue
            val colonIdx = firstUnescapedColon(token)
            if (colonIdx < 0) continue
            val key = token.substring(0, colonIdx)
            val valRaw = token.substring(colonIdx + 1)
            fields[key] = valRaw
        }

        if (fields["T"] != "ADB") throw ContinuityPairingException("Unsupported Continuity pairing QR format")
        val serviceName = fields["S"]?.let(::unescape)?.takeIf { it.isNotEmpty() }
            ?: throw ContinuityPairingException("Missing service field in QR")
        val rawPin = fields["P"]?.let(::unescape)
            ?: throw ContinuityPairingException("Missing pairing code in QR")
        val pin = normalizePin(rawPin)
        if (pin.length != 6) throw ContinuityPairingException("Invalid 6-digit pairing code in QR")
        val deviceId = fields["ID"]?.let(::unescape)?.takeIf { it.isNotEmpty() }
            ?: throw ContinuityPairingException("Missing device ID in QR")
        val deviceName = fields["NAME"]?.let(::unescape)?.takeIf { it.isNotEmpty() }
            ?: throw ContinuityPairingException("Missing device name in QR")
        val fingerprint = fields["FP"]?.let(::unescape)?.takeIf { it.isNotEmpty() }
            ?: throw ContinuityPairingException("Missing certificate fingerprint in QR")
        val expiresAt = fields["EXP"]?.toLongOrNull()
            ?: throw ContinuityPairingException("Missing expiry timestamp in QR")

        if (validateExpiry && expiresAt > 0L && nowEpochSeconds > expiresAt) {
            throw ContinuityPairingException("This QR pairing code has expired — refresh it on your Mac")
        }

        val endpoints = mutableListOf<ContinuityEndpoint>()
        val rawEps = fields["EP"].orEmpty()
        if (rawEps.isNotEmpty()) {
            for (entry in splitUnescaped(rawEps, ',')) {
                if (entry.isEmpty()) continue
                val atIdx = entry.indexOf('@')
                if (atIdx >= 0) {
                    val addr = unescape(entry.substring(0, atIdx))
                    val kind = entry.substring(atIdx + 1).ifEmpty { "lan" }
                    endpoints += ContinuityEndpoint(address = addr, kind = kind)
                } else {
                    endpoints += ContinuityEndpoint(address = unescape(entry), kind = "lan")
                }
            }
        }

        return ContinuityPairingPayload(
            serviceName = serviceName,
            passcode = pin,
            deviceId = deviceId,
            deviceName = deviceName,
            fingerprint = fingerprint,
            endpoints = endpoints,
            expiresAt = expiresAt
        )
    }

    private fun escape(value: String): String = value
        .replace("\\", "\\\\")
        .replace(";", "\\;")
        .replace(":", "\\:")
        .replace(",", "\\,")

    private fun unescape(value: String): String {
        val out = StringBuilder(value.length)
        var escaped = false
        for (ch in value) {
            if (escaped) {
                out.append(ch)
                escaped = false
            } else if (ch == '\\') {
                escaped = true
            } else {
                out.append(ch)
            }
        }
        if (escaped) out.append('\\')
        return out.toString()
    }

    private fun splitUnescaped(value: String, delimiter: Char): List<String> {
        val parts = mutableListOf<String>()
        val current = StringBuilder()
        var escaped = false
        for (ch in value) {
            if (escaped) {
                current.append('\\').append(ch)
                escaped = false
            } else if (ch == '\\') {
                escaped = true
            } else if (ch == delimiter) {
                parts += current.toString()
                current.setLength(0)
            } else {
                current.append(ch)
            }
        }
        if (escaped) current.append('\\')
        if (current.isNotEmpty()) parts += current.toString()
        return parts
    }

    private fun firstUnescapedColon(value: String): Int {
        var escaped = false
        for (i in value.indices) {
            val ch = value[i]
            if (escaped) {
                escaped = false
            } else if (ch == '\\') {
                escaped = true
            } else if (ch == ':') {
                return i
            }
        }
        return -1
    }
}
