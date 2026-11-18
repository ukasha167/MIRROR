package dev.mirror.companion

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.net.wifi.WifiManager
import android.provider.Settings

/**
 * Android's Wireless debugging switch is the global setting `adb_wifi_enabled`
 * (`Settings.Global.ADB_WIFI_ENABLED`, hidden from the SDK). `AdbService` watches it and
 * starts adbd's TLS listener, which advertises `_adb-tls-connect._tcp` over mDNS. The Mac
 * already looks for that service when its saved address fails.
 *
 * Android sets it back to 0 at boot and whenever Wi-Fi drops.
 */
object AdbWifi {
    private const val SETTING = "adb_wifi_enabled"

    fun canWrite(context: Context): Boolean =
        context.checkSelfPermission(Manifest.permission.WRITE_SECURE_SETTINGS) ==
            PackageManager.PERMISSION_GRANTED

    fun canReadNetworkName(context: Context): Boolean =
        context.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED

    fun isOn(context: Context): Boolean =
        Settings.Global.getInt(context.contentResolver, SETTING, 0) == 1

    /** Returns false when the Mac has not granted WRITE_SECURE_SETTINGS. */
    fun set(context: Context, on: Boolean): Boolean {
        if (!canWrite(context)) return false
        return try {
            Settings.Global.putInt(context.contentResolver, SETTING, if (on) 1 else 0)
        } catch (e: SecurityException) {
            false
        }
    }

    /** The raw `WifiInfo.getSSID()` value; see [NetworkApproval.normalize]. */
    @Suppress("DEPRECATION") // The callback form needs a live process; this is a one-shot read.
    fun currentRawSsid(context: Context): String? {
        val wifi = context.getSystemService(WifiManager::class.java) ?: return null
        return wifi.connectionInfo?.ssid
    }

    fun currentSsid(context: Context): String? = NetworkApproval.normalize(currentRawSsid(context))
}
