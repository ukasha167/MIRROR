package dev.mirror.continuity.network

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Tracks discovered Continuity Mac peers across both NSD Wi-Fi and direct USB sockets,
 * and combines USB_STATE data attachment with BATTERY_PLUGGED_USB fallback.
 */
internal class ContinuityDiscoveryTracker {
    private val lock = Any()
    private var nsdHelper: ContinuityNsdHelper? = null
    private var socketMacs: List<DiscoveredMacPeer> = emptyList()
    private var nsdMacs: List<DiscoveredMacPeer> = emptyList()

    @Volatile private var usbDataCableAttached: Boolean = false
    @Volatile private var usbPowerPlugged: Boolean = false

    private val _discoveredMacsFlow = MutableStateFlow<List<DiscoveredMacPeer>>(emptyList())
    val discoveredMacsFlow: StateFlow<List<DiscoveredMacPeer>> = _discoveredMacsFlow.asStateFlow()

    private val _isUsbCableAttachedFlow = MutableStateFlow(false)
    val isUsbCableAttachedFlow: StateFlow<Boolean> = _isUsbCableAttachedFlow.asStateFlow()

    fun startOrRestartNsd(
        appContext: Context,
        store: ContinuityPrefsStore,
        listenPort: Int,
        onMacFoundWithTrust: (DiscoveredMacPeer) -> Unit
    ) {
        synchronized(lock) {
            nsdMacs = emptyList()
            publishLocked()
        }
        nsdHelper?.stop()
        val helper = ContinuityNsdHelper(
            context = appContext,
            localDeviceId = store.getOrCreateLocalDeviceId(),
            localDeviceName = store.getLocalDeviceName(),
            localModel = store.getLocalDeviceModel(),
            onMacsUpdated = { macs ->
                synchronized(lock) {
                    nsdMacs = macs
                    publishLocked()
                }
                if (store.getTrustedMac() != null) {
                    macs.firstOrNull()?.let(onMacFoundWithTrust)
                }
            }
        )
        nsdHelper = helper
        helper.start(listenPort)
    }

    fun updateUsbState(
        dataAttached: Boolean?,
        powerPlugged: Boolean?,
        onUsbNewlyAttached: () -> Unit
    ) {
        val wasUsb = _isUsbCableAttachedFlow.value
        if (dataAttached != null) usbDataCableAttached = dataAttached
        if (powerPlugged != null) usbPowerPlugged = powerPlugged
        val nowUsb = usbDataCableAttached || usbPowerPlugged
        _isUsbCableAttachedFlow.value = nowUsb
        if (!nowUsb) {
            clearUsbSocketMacs()
        } else if (!wasUsb) {
            onUsbNewlyAttached()
        }
    }

    fun upsertSocketMac(mac: DiscoveredMacPeer) {
        synchronized(lock) {
            socketMacs = socketMacs.filterNot { it.id == mac.id } + mac
            publishLocked()
        }
    }

    fun removeSocketPeer(id: String, viaUsb: Boolean) {
        synchronized(lock) {
            socketMacs = socketMacs.filterNot { it.id == id && it.viaUsb == viaUsb }
            publishLocked()
        }
    }

    fun clearUsbSocketMacs() {
        synchronized(lock) {
            socketMacs = socketMacs.filterNot { it.viaUsb }
            publishLocked()
        }
    }

    fun hasUsbSocketMac(): Boolean = synchronized(lock) { socketMacs.any { it.viaUsb } }

    private fun publishLocked() {
        _discoveredMacsFlow.value = ContinuityProtocolRouter.mergeDiscoveredMacs(socketMacs, nsdMacs)
    }
}
