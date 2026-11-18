package dev.mirror.companion

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.NetworkRequest

/**
 * Asks Android to wake [CompanionReceiver] each time the phone joins Wi-Fi.
 *
 * The PendingIntent form of `registerNetworkCallback` lives in the system, not in our
 * process: no service, no wakelock, nothing running while the phone is away from home.
 * Android drops it at reboot, so the receiver registers it again on BOOT_COMPLETED.
 * Registering the same PendingIntent again replaces the earlier registration.
 */
object WifiWatch {
    const val ACTION_WIFI_AVAILABLE = "dev.mirror.companion.WIFI_AVAILABLE"
    private const val REQUEST_CODE = 1

    fun register(context: Context) {
        val connectivity = context.getSystemService(ConnectivityManager::class.java) ?: return
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .build()
        connectivity.registerNetworkCallback(request, pendingIntent(context))
    }

    private fun pendingIntent(context: Context): PendingIntent {
        val intent = Intent(context, CompanionReceiver::class.java).setAction(ACTION_WIFI_AVAILABLE)
        // Mutable: ConnectivityManager adds the Network to the intent's extras.
        return PendingIntent.getBroadcast(
            context,
            REQUEST_CODE,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
        )
    }
}
