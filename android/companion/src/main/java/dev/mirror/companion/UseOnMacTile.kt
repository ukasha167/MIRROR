package dev.mirror.companion

import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

/**
 * "Use on Mac": turns Wireless debugging on or off on the current network by hand.
 *
 * On a network Android does not trust yet, Android shows its own dialog the first time;
 * ticking "Always allow on this network" there stops it asking again. The tile does not
 * add the network to the app's approved list: approval happens from the Mac or the app.
 */
class UseOnMacTile : TileService() {

    override fun onStartListening() {
        super.onStartListening()
        refresh()
    }

    override fun onClick() {
        super.onClick()
        if (!AdbWifi.canWrite(this)) {
            openApp()
            return
        }
        AdbWifi.set(this, !AdbWifi.isOn(this))
        refresh()
    }

    private fun refresh() {
        val tile = qsTile ?: return
        val canWrite = AdbWifi.canWrite(this)
        val on = canWrite && AdbWifi.isOn(this)
        // Not STATE_UNAVAILABLE without the permission: Android sends no clicks to an
        // unavailable tile, and the click is what opens the setup screen.
        tile.state = if (on) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
        tile.subtitle = getString(
            when {
                !canWrite -> R.string.tile_needs_setup
                on -> R.string.tile_on
                else -> R.string.tile_off
            }
        )
        tile.updateTile()
    }

    private fun openApp() {
        val intent = Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            val pending = PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_IMMUTABLE)
            startActivityAndCollapse(pending)
        } else {
            @Suppress("DEPRECATION", "StartActivityAndCollapseDeprecated")
            startActivityAndCollapse(intent)
        }
    }
}
