package dev.mirror.companion

import android.content.Context

/** Wi-Fi names where the phone may turn Wireless debugging on by itself. */
class ApprovedNetworks(context: Context) {
    // Device-protected storage: BOOT_COMPLETED can arrive before the user unlocks
    // with direct boot, and credential storage is not readable then.
    private val prefs = context.createDeviceProtectedStorageContext()
        .getSharedPreferences("approved_networks", Context.MODE_PRIVATE)

    fun all(): Set<String> = prefs.getStringSet(KEY, emptySet()).orEmpty().toSortedSet()

    fun add(ssid: String) = save(all() + ssid)

    fun remove(ssid: String) = save(all() - ssid)

    private fun save(set: Set<String>) {
        // getStringSet's result must not be modified in place, so always write a copy.
        prefs.edit().putStringSet(KEY, HashSet(set)).apply()
    }

    private companion object {
        const val KEY = "ssids"
    }
}
