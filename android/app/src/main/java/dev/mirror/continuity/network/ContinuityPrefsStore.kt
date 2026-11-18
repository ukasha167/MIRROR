package dev.mirror.continuity.network

import android.content.Context
import android.os.Build
import android.provider.Settings
import java.security.SecureRandom
import java.util.UUID

data class TrustedMacPeer(
    val id: String,
    val name: String,
    val pairToken: String
)

data class ContinuityFeaturePrefs(
    val clipboardSync: Boolean = true,
    val notificationMirror: Boolean = true,
    val otpAutofill: Boolean = true,
    val mediaHandoff: Boolean = true,
    val quickShareTarget: Boolean = true
)

/**
 * SharedPreferences-backed persistence for trusted Mac credentials, local device identity, and Continuity toggles.
 */
class ContinuityPrefsStore(context: Context) {
    private val prefs = context.applicationContext.getSharedPreferences("mirror_continuity_prefs_v1", Context.MODE_PRIVATE)
    private val appContext = context.applicationContext
    private val random = SecureRandom()

    fun getOrCreateLocalDeviceId(): String {
        val existing = prefs.getString(KEY_DEVICE_ID, null)
        if (!existing.isNullOrBlank()) return existing
        val created = "android-" + UUID.randomUUID().toString().lowercase()
        prefs.edit().putString(KEY_DEVICE_ID, created).apply()
        return created
    }

    fun getLocalDeviceName(): String {
        val userName = runCatching {
            Settings.Global.getString(appContext.contentResolver, Settings.Global.DEVICE_NAME)
        }.getOrNull()?.trim()
        if (!userName.isNullOrEmpty()) return userName
        return Build.MODEL?.takeIf { it.isNotBlank() } ?: "Android Phone"
    }

    fun getLocalDeviceModel(): String = Build.MODEL?.takeIf { it.isNotBlank() } ?: "Android"

    fun getTrustedMac(): TrustedMacPeer? {
        val id = prefs.getString(KEY_MAC_ID, null) ?: return null
        val name = prefs.getString(KEY_MAC_NAME, null) ?: return null
        val token = prefs.getString(KEY_MAC_TOKEN, null) ?: return null
        if (id.isBlank() || token.isBlank()) return null
        return TrustedMacPeer(id = id, name = name, pairToken = token)
    }

    fun saveTrustedMac(peer: TrustedMacPeer) {
        prefs.edit()
            .putString(KEY_MAC_ID, peer.id)
            .putString(KEY_MAC_NAME, peer.name)
            .putString(KEY_MAC_TOKEN, peer.pairToken)
            .apply()
    }

    fun clearTrustedMac() {
        prefs.edit()
            .remove(KEY_MAC_ID)
            .remove(KEY_MAC_NAME)
            .remove(KEY_MAC_TOKEN)
            .apply()
    }

    fun getFeaturePrefs(): ContinuityFeaturePrefs {
        return ContinuityFeaturePrefs(
            clipboardSync = prefs.getBoolean(KEY_CLIPBOARD, true),
            notificationMirror = prefs.getBoolean(KEY_NOTIF, true),
            otpAutofill = prefs.getBoolean(KEY_OTP, true),
            mediaHandoff = prefs.getBoolean(KEY_MEDIA, true),
            quickShareTarget = prefs.getBoolean(KEY_QUICKSHARE, true)
        )
    }

    fun saveFeaturePrefs(features: ContinuityFeaturePrefs) {
        prefs.edit()
            .putBoolean(KEY_CLIPBOARD, features.clipboardSync)
            .putBoolean(KEY_NOTIF, features.notificationMirror)
            .putBoolean(KEY_OTP, features.otpAutofill)
            .putBoolean(KEY_MEDIA, features.mediaHandoff)
            .putBoolean(KEY_QUICKSHARE, features.quickShareTarget)
            .apply()
    }

    fun generatePairToken(): String {
        val bytes = ByteArray(16)
        random.nextBytes(bytes)
        return bytes.joinToString("") { "%02x".format(it) }
    }

    companion object {
        private const val KEY_DEVICE_ID = "local_device_id"
        private const val KEY_MAC_ID = "trusted_mac_id"
        private const val KEY_MAC_NAME = "trusted_mac_name"
        private const val KEY_MAC_TOKEN = "trusted_mac_token"
        private const val KEY_CLIPBOARD = "feat_clipboard"
        private const val KEY_NOTIF = "feat_notifications"
        private const val KEY_OTP = "feat_otp"
        private const val KEY_MEDIA = "feat_media"
        private const val KEY_QUICKSHARE = "feat_quickshare"
    }
}
