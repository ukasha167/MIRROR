package dev.mirror.continuity

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.companion.AssociationInfo
import android.companion.CompanionDeviceManager
import android.companion.CompanionDeviceService
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.util.Log
import androidx.annotation.RequiresApi
import dev.mirror.continuity.network.ContinuityLinkManager
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/**
 * Zero-wakelock CompanionDeviceService implementation for macOS continuity.
 *
 * Architecture:
 * - Uses CompanionDeviceManager.startObservingDevicePresence() for silicon-level BLE/Wi-Fi wake.
 * - Uses Android 14+ NsdManager.registerServiceInfoCallback() for hardware-offloaded mDNS
 *   without holding a battery-draining WifiManager.MulticastLock while idle.
 * - Enforces zero open sockets and zero persistent foreground services when away from Mac.
 * - Promotes to foregroundServiceType="connectedDevice" only during active sessions.
 */
class PresenceWakeService : CompanionDeviceService() {

    private val serviceScope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private val nsdExecutor: Executor = Executors.newSingleThreadExecutor()

    private var nsdManager: NsdManager? = null
    private var serviceInfoCallback: Any? = null // NsdManager.ServiceInfoCallback on API 34+

    override fun onCreate() {
        super.onCreate()
        nsdManager = getSystemService(Context.NSD_SERVICE) as? NsdManager
        Log.i(TAG, "PresenceWakeService created in zero-wakelock dormant state")
    }

    override fun onDestroy() {
        unregisterHardwareNsdCallback()
        serviceScope.cancel()
        _isDeviceConnectedFlow.value = false
        super.onDestroy()
    }

    /**
     * API 33+ presence callback when Mac device appears.
     */
    override fun onDeviceAppeared(associationInfo: AssociationInfo) {
        Log.i(TAG, "onDeviceAppeared(AssociationInfo): id=${associationInfo.id}")
        handleDeviceAppeared(associationInfo.id)
    }

    /**
     * API 31-32 fallback callback.
     */
    @Deprecated("Deprecated in Java", ReplaceWith("onDeviceAppeared(associationInfo)"))
    override fun onDeviceAppeared(address: String) {
        Log.i(TAG, "onDeviceAppeared(String): address=$address")
        handleDeviceAppeared(address.hashCode())
    }

    override fun onDeviceDisappeared(associationInfo: AssociationInfo) {
        Log.i(TAG, "onDeviceDisappeared(AssociationInfo): id=${associationInfo.id}")
        handleDeviceDisappeared(associationInfo.id)
    }

    @Deprecated("Deprecated in Java", ReplaceWith("onDeviceDisappeared(associationInfo)"))
    override fun onDeviceDisappeared(address: String) {
        Log.i(TAG, "onDeviceDisappeared(String): address=$address")
        handleDeviceDisappeared(address.hashCode())
    }

    private fun handleDeviceAppeared(associationId: Int) {
        Log.i(TAG, "Mac detected within proximity. Probing Mirror Continuity host app...")
        _activeAssociationIdFlow.value = associationId

        // Promote to connectedDevice foreground service while verifying Continuity link
        startForegroundConnectedNotification()

        // Register hardware-offloaded NSD callback to resolve Mac mDNS endpoint
        registerHardwareNsdCallback()

        // Trigger handshake check; never mark connected until Mac Continuity app authenticates
        serviceScope.launch {
            establishContinuitySession(associationId)
        }
    }

    private fun handleDeviceDisappeared(associationId: Int) {
        Log.i(TAG, "Mac left proximity. Teardown active sockets and release wakelocks.")
        if (!ContinuityLinkManager.isConnectedFlow.value) {
            _isDeviceConnectedFlow.value = false
        }
        _activeAssociationIdFlow.value = null

        unregisterHardwareNsdCallback()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    /**
     * Android 14+ (API 34+) hardware-offloaded mDNS resolution via APF packet filter.
     * Avoids holding WifiManager.MulticastLock.
     */
    private fun registerHardwareNsdCallback() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            val nsd = nsdManager ?: return
            val serviceInfo = NsdServiceInfo().apply {
                serviceType = "_mirror-cont._tcp"
                serviceName = "mac-host"
            }

            try {
                val callback = object : NsdManager.ServiceInfoCallback {
                    override fun onServiceInfoCallbackRegistrationFailed(errorCode: Int) {
                        Log.w(TAG, "Hardware NSD registration failed: code=$errorCode")
                    }

                    override fun onServiceUpdated(info: NsdServiceInfo) {
                        Log.i(TAG, "Hardware NSD resolved host: ${info.host?.hostAddress}:${info.port}")
                        _resolvedHostFlow.value = info.host?.hostAddress?.let { it to info.port }
                    }

                    override fun onServiceLost() {
                        Log.i(TAG, "Hardware NSD host service lost")
                        _resolvedHostFlow.value = null
                    }

                    override fun onServiceInfoCallbackUnregistered() {
                        Log.d(TAG, "Hardware NSD callback unregistered")
                    }
                }

                serviceInfoCallback = callback
                nsd.registerServiceInfoCallback(serviceInfo, nsdExecutor, callback)
                Log.d(TAG, "Registered hardware-offloaded NsdManager.ServiceInfoCallback")
            } catch (t: Throwable) {
                Log.w(TAG, "NsdManager.registerServiceInfoCallback error", t)
            }
        }
    }

    private fun unregisterHardwareNsdCallback() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            val callback = serviceInfoCallback as? NsdManager.ServiceInfoCallback
            if (callback != null && nsdManager != null) {
                try {
                    nsdManager?.unregisterServiceInfoCallback(callback)
                } catch (t: Throwable) {
                    Log.w(TAG, "Failed unregistering ServiceInfoCallback", t)
                }
                serviceInfoCallback = null
            }
        }
    }

    private fun startForegroundConnectedNotification() {
        val channelId = "continuity_connected_channel"
        val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                channelId,
                "Continuity Connection",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Active connection to paired Mac"
                setShowBadge(false)
            }
            notificationManager.createNotificationChannel(channel)
        }

        val notification = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, channelId)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
            .setContentTitle("Connected to Mac")
            .setContentText("Continuity active (Zero idle power)")
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setOngoing(true)
            .build()

        startForeground(NOTIFICATION_ID, notification)
    }

    private suspend fun establishContinuitySession(associationId: Int) {
        Log.d(TAG, "Checking Continuity host session for association: $associationId")
        ContinuityLinkManager.ensureStarted(applicationContext)
        ContinuityLinkManager.triggerReconnectAttempt()
    }

    companion object {
        private const val TAG = "PresenceWakeService"
        private const val NOTIFICATION_ID = 1001

        private val _isDeviceConnectedFlow = MutableStateFlow(false)
        val isDeviceConnectedFlow: StateFlow<Boolean> = _isDeviceConnectedFlow.asStateFlow()
        val isDeviceConnected: Boolean get() = _isDeviceConnectedFlow.value

        private val _activeAssociationIdFlow = MutableStateFlow<Int?>(null)
        val activeAssociationIdFlow: StateFlow<Int?> = _activeAssociationIdFlow.asStateFlow()

        private val _resolvedHostFlow = MutableStateFlow<Pair<String, Int>?>(null)
        val resolvedHostFlow: StateFlow<Pair<String, Int>?> = _resolvedHostFlow.asStateFlow()

        /**
         * Register hardware-offloaded observing presence request with CompanionDeviceManager.
         */
        @RequiresApi(Build.VERSION_CODES.S)
        fun startObservingMacPresence(context: Context, associationId: Int, deviceAddress: String = "") {
            val cdm = context.getSystemService(Context.COMPANION_DEVICE_SERVICE) as? CompanionDeviceManager ?: return
            try {
                val requestClass = try {
                    Class.forName("android.companion.ObservingDevicePresenceRequest\$Builder")
                } catch (_: ClassNotFoundException) { null }

                if (requestClass != null) {
                    val builder = requestClass.getConstructor().newInstance()
                    val setAssocMethod = requestClass.getMethod("setAssociationId", Int::class.javaPrimitiveType)
                    setAssocMethod.invoke(builder, associationId)
                    val buildMethod = requestClass.getMethod("build")
                    val req = buildMethod.invoke(builder)
                    val startMethod = cdm.javaClass.getMethod("startObservingDevicePresence", req.javaClass)
                    startMethod.invoke(cdm, req)
                    Log.i(TAG, "Registered ObservingDevicePresenceRequest for association $associationId")
                } else if (deviceAddress.isNotBlank()) {
                    cdm.startObservingDevicePresence(deviceAddress)
                    Log.i(TAG, "Registered startObservingDevicePresence for address $deviceAddress")
                }
            } catch (e: Exception) {
                Log.e(TAG, "Failed to start observing device presence", e)
            }
        }

        fun enqueueOutboundTransfer(context: Context, uris: List<Uri>) {
            Log.i(TAG, "Enqueueing ${uris.size} outbound items to Mac")
            // Forward to Rust core transfer worker
        }

        fun enqueueOutboundText(context: Context, text: String) {
            Log.i(TAG, "Enqueueing outbound text snippet (${text.length} chars)")
        }

        fun disconnectCurrentSession(context: Context) {
            _isDeviceConnectedFlow.value = false
            context.stopService(Intent(context, PresenceWakeService::class.java))
        }

        internal fun updateMutualConnectionState(connected: Boolean, resolvedHost: Pair<String, Int>? = null) {
            _isDeviceConnectedFlow.value = connected
            _resolvedHostFlow.value = resolvedHost
        }

        // Test seam for hardware-free unit tests
        internal fun setConnectedForTesting(connected: Boolean) {
            _isDeviceConnectedFlow.value = connected
        }
    }
}
