package dev.mirror.continuity

import android.content.Intent
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

/**
 * Quick Settings tile providing one-tap toggle for Mac continuity connection.
 */
class ContinuityQuickSettingsTile : TileService() {

    override fun onStartListening() {
        super.onStartListening()
        updateTileState(PresenceWakeService.isDeviceConnected)
    }

    override fun onClick() {
        super.onClick()
        val isConnected = PresenceWakeService.isDeviceConnected
        if (isConnected) {
            PresenceWakeService.disconnectCurrentSession(this)
            updateTileState(false)
        } else {
            val appIntent = Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            }
            startActivityAndCollapse(appIntent)
        }
    }

    private fun updateTileState(active: Boolean) {
        val tile = qsTile ?: return
        tile.state = if (active) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
        tile.label = getString(R.string.quick_settings_tile_label)
        tile.contentDescription = if (active) {
            getString(R.string.status_connected)
        } else {
            getString(R.string.status_idle)
        }
        tile.updateTile()
    }
}
