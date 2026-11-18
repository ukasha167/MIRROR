package dev.mirror.companion

/** What to do when the phone joins a Wi-Fi network. Pure, so tests need no phone. */
sealed interface WifiDecision {
    /** Turn Wireless debugging on. */
    data object TurnOn : WifiDecision
    data object AlreadyOn : WifiDecision
    /** The Mac has not run `pm grant ... WRITE_SECURE_SETTINGS` yet. */
    data object NoPermission : WifiDecision
    /** Android hid the network name: location is off or not granted. */
    data object UnknownNetwork : WifiDecision
    /**
     * Not on the approved list. Turning it on here would make Android show its own
     * "Allow wireless debugging on this network?" dialog on every cafe Wi-Fi.
     */
    data class NotApproved(val ssid: String) : WifiDecision
}

object NetworkApproval {
    /** Android's placeholder when the caller may not see the network name. */
    private const val UNKNOWN_SSID = "<unknown ssid>"

    /**
     * `WifiInfo.getSSID()` returns `"name"` in double quotes for UTF-8 names, bare hex for
     * other names, and `<unknown ssid>` when hidden. Returns the bare name, or null.
     */
    fun normalize(raw: String?): String? {
        val trimmed = raw?.trim() ?: return null
        if (trimmed.isEmpty() || trimmed == UNKNOWN_SSID) return null
        val bare = if (trimmed.length >= 2 && trimmed.startsWith('"') && trimmed.endsWith('"')) {
            trimmed.substring(1, trimmed.length - 1)
        } else {
            trimmed
        }
        return bare.ifEmpty { null }
    }

    fun decide(
        rawSsid: String?,
        approved: Set<String>,
        alreadyOn: Boolean,
        canWriteSettings: Boolean,
    ): WifiDecision {
        if (!canWriteSettings) return WifiDecision.NoPermission
        if (alreadyOn) return WifiDecision.AlreadyOn
        val ssid = normalize(rawSsid) ?: return WifiDecision.UnknownNetwork
        return if (ssid in approved) WifiDecision.TurnOn else WifiDecision.NotApproved(ssid)
    }
}
