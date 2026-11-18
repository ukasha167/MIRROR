package dev.mirror.companion

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Every way the app wakes up without a screen:
 *
 * - `BOOT_COMPLETED`, `MY_PACKAGE_REPLACED`: register [WifiWatch] again.
 * - [WifiWatch.ACTION_WIFI_AVAILABLE]: the phone joined Wi-Fi; turn Wireless debugging on
 *   if this network is approved.
 * - [ACTION_APPROVE_NETWORK]: sent by the Mac over USB right after `pm grant`. Approves the
 *   current network (or the `ssid` extra) and turns Wireless debugging on. The result data
 *   is `approved:<name>` or `error:<reason>`, which `am broadcast` prints for the Mac.
 */
class CompanionReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED -> {
                WifiWatch.register(context)
                // At boot Wi-Fi may already be up; the callback also fires for it, but
                // checking now costs nothing.
                onWifiAvailable(context)
            }
            WifiWatch.ACTION_WIFI_AVAILABLE -> onWifiAvailable(context)
            ACTION_APPROVE_NETWORK -> approve(context, intent.getStringExtra(EXTRA_SSID))
        }
    }

    private fun onWifiAvailable(context: Context) {
        val decision = NetworkApproval.decide(
            rawSsid = AdbWifi.currentRawSsid(context),
            approved = ApprovedNetworks(context).all(),
            alreadyOn = AdbWifi.isOn(context),
            canWriteSettings = AdbWifi.canWrite(context),
        )
        Log.i(TAG, "Wi-Fi available: $decision")
        if (decision == WifiDecision.TurnOn) AdbWifi.set(context, true)
    }

    private fun approve(context: Context, ssidExtra: String?) {
        val ssid = NetworkApproval.normalize(ssidExtra) ?: AdbWifi.currentSsid(context)
        val result = when {
            !AdbWifi.canWrite(context) -> "error:no WRITE_SECURE_SETTINGS"
            ssid == null -> "error:network name hidden (location off or not granted)"
            else -> {
                ApprovedNetworks(context).add(ssid)
                WifiWatch.register(context)
                AdbWifi.set(context, true)
                "approved:$ssid"
            }
        }
        Log.i(TAG, "Approve request: $result")
        resultCode = if (result.startsWith("approved:")) Activity.RESULT_OK else Activity.RESULT_CANCELED
        resultData = result
    }

    companion object {
        const val ACTION_APPROVE_NETWORK = "dev.mirror.companion.APPROVE_NETWORK"
        const val EXTRA_SSID = "ssid"
        private const val TAG = "MirrorCompanion"
    }
}
