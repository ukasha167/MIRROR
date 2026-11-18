package dev.mirror.continuity.network

/**
 * Pure-Kotlin NDJSON Continuity message matching macOS `ContinuityWireMessage`.
 * Uses zero Android-runtime JSON classes so it tests cleanly on the JVM.
 */
data class ContinuityWireMessage(
    val type: String,
    val deviceId: String,
    val deviceName: String,
    val deviceModel: String,
    val role: String,
    val code: String? = null,
    val pairToken: String? = null,
    val accepted: Boolean? = null,
    val reason: String? = null,
    val batteryLevel: Int? = null,
    val isCharging: Boolean? = null,
    val adbSerial: String? = null,
    val listeningPort: Int? = null,
    val mediaTitle: String? = null,
    val mediaArtist: String? = null,
    val mediaPlaying: Boolean? = null,
    val clipboardText: String? = null,
    val timestampMs: Long? = null
) {
    fun toJsonLine(): String {
        val entries = mutableListOf<String>()
        fun addStr(k: String, v: String?) {
            if (v != null) entries += "\"${escapeJson(k)}\":\"${escapeJson(v)}\""
        }
        fun addBool(k: String, v: Boolean?) {
            if (v != null) entries += "\"${escapeJson(k)}\":$v"
        }
        fun addNum(k: String, v: Number?) {
            if (v != null) entries += "\"${escapeJson(k)}\":$v"
        }

        addStr("type", type)
        addStr("deviceId", deviceId)
        addStr("deviceName", deviceName)
        addStr("deviceModel", deviceModel)
        addStr("role", role)
        addStr("code", code)
        addStr("pairToken", pairToken)
        addBool("accepted", accepted)
        addStr("reason", reason)
        addNum("batteryLevel", batteryLevel)
        addBool("isCharging", isCharging)
        addStr("adbSerial", adbSerial)
        addNum("listeningPort", listeningPort)
        addStr("mediaTitle", mediaTitle)
        addStr("mediaArtist", mediaArtist)
        addBool("mediaPlaying", mediaPlaying)
        addStr("clipboardText", clipboardText)
        addNum("timestampMs", timestampMs)

        return entries.joinToString(prefix = "{", postfix = "}")
    }

    companion object {
        fun fromJsonLine(line: String): ContinuityWireMessage? {
            val map = parseFlatJsonObject(line) ?: return null
            val type = map["type"] as? String ?: return null
            val deviceId = map["deviceId"] as? String ?: return null
            val deviceName = map["deviceName"] as? String ?: "Unknown"
            val deviceModel = map["deviceModel"] as? String ?: "Device"
            val role = map["role"] as? String ?: ""
            return ContinuityWireMessage(
                type = type,
                deviceId = deviceId,
                deviceName = deviceName,
                deviceModel = deviceModel,
                role = role,
                code = map["code"] as? String,
                pairToken = map["pairToken"] as? String,
                accepted = map["accepted"] as? Boolean,
                reason = map["reason"] as? String,
                batteryLevel = (map["batteryLevel"] as? Long)?.toInt(),
                isCharging = map["isCharging"] as? Boolean,
                adbSerial = map["adbSerial"] as? String,
                listeningPort = (map["listeningPort"] as? Long)?.toInt(),
                mediaTitle = map["mediaTitle"] as? String,
                mediaArtist = map["mediaArtist"] as? String,
                mediaPlaying = map["mediaPlaying"] as? Boolean,
                clipboardText = map["clipboardText"] as? String,
                timestampMs = map["timestampMs"] as? Long
            )
        }

        private fun escapeJson(s: String): String {
            val sb = StringBuilder(s.length)
            for (ch in s) {
                when (ch) {
                    '\\' -> sb.append("\\\\")
                    '"' -> sb.append("\\\"")
                    '\n' -> sb.append("\\n")
                    '\r' -> sb.append("\\r")
                    '\t' -> sb.append("\\t")
                    else -> {
                        if (ch.code < 0x20) sb.append("\\u%04x".format(ch.code))
                        else sb.append(ch)
                    }
                }
            }
            return sb.toString()
        }

        private fun parseFlatJsonObject(input: String): Map<String, Any?>? {
            val s = input.trim()
            if (!s.startsWith("{") || !s.endsWith("}")) return null
            var i = 1
            val n = s.length - 1
            val map = mutableMapOf<String, Any?>()

            fun skipWs() { while (i < n && s[i].isWhitespace()) i++ }

            fun readString(): String? {
                if (i >= n || s[i] != '"') return null
                i++
                val sb = StringBuilder()
                while (i < n) {
                    val c = s[i++]
                    if (c == '"') return sb.toString()
                    if (c == '\\') {
                        if (i >= n) return null
                        when (val esc = s[i++]) {
                            '"' -> sb.append('"')
                            '\\' -> sb.append('\\')
                            '/' -> sb.append('/')
                            'n' -> sb.append('\n')
                            'r' -> sb.append('\r')
                            't' -> sb.append('\t')
                            'u' -> {
                                if (i + 4 > n) return null
                                val code = s.substring(i, i + 4).toIntOrNull(16) ?: return null
                                sb.append(code.toChar())
                                i += 4
                            }
                            else -> sb.append(esc)
                        }
                    } else {
                        sb.append(c)
                    }
                }
                return null
            }

            while (i < n) {
                skipWs()
                if (i >= n) break
                val key = readString() ?: return null
                skipWs()
                if (i >= n || s[i++] != ':') return null
                skipWs()
                if (i >= n) return null
                val value: Any? = when {
                    s[i] == '"' -> readString() ?: return null
                    s.startsWith("true", i) -> { i += 4; true }
                    s.startsWith("false", i) -> { i += 5; false }
                    s.startsWith("null", i) -> { i += 4; null }
                    else -> {
                        val start = i
                        while (i < n && s[i] != ',' && !s[i].isWhitespace()) i++
                        s.substring(start, i).toLongOrNull()
                    }
                }
                map[key] = value
                skipWs()
                if (i < n && s[i] == ',') i++
            }
            return map
        }
    }
}

/**
 * Pure policy helper verifying that a device is considered connected ONLY after mutual Continuity app verification.
 * Charging or plugging in a USB cable alone must never transition connection state to connected.
 */
object ContinuityConnectionPolicy {
    fun evaluateMutualConnection(
        isHandshakeVerified: Boolean,
        verifiedMacName: String?,
        isUsbCableAttached: Boolean
    ): ContinuityUiConnectionStatus {
        return when {
            isHandshakeVerified && !verifiedMacName.isNullOrBlank() ->
                ContinuityUiConnectionStatus.Connected(macName = verifiedMacName)
            isUsbCableAttached ->
                ContinuityUiConnectionStatus.UsbWaitingForMacApp
            else ->
                ContinuityUiConnectionStatus.Disconnected
        }
    }
}

sealed class ContinuityUiConnectionStatus {
    data class Connected(val macName: String) : ContinuityUiConnectionStatus()
    data object UsbWaitingForMacApp : ContinuityUiConnectionStatus()
    data object Disconnected : ContinuityUiConnectionStatus()
}
