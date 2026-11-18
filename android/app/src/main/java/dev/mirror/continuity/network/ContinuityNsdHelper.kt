package dev.mirror.continuity.network

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.util.Log
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

data class DiscoveredMacPeer(
    val id: String,
    val name: String,
    val host: String,
    val port: Int,
    val viaUsb: Boolean = false
)

/**
 * Registers Android Continuity presence over DNS-SD (`_mirror-cont._tcp.`)
 * and discovers Mac Continuity hosts without persistent MulticastLock drain.
 */
class ContinuityNsdHelper(
    context: Context,
    private val localDeviceId: String,
    private val localDeviceName: String,
    private val localModel: String,
    private val onMacsUpdated: (List<DiscoveredMacPeer>) -> Unit
) {
    private val nsdManager = context.applicationContext.getSystemService(Context.NSD_SERVICE) as? NsdManager
    private val callbackExecutor = Executors.newSingleThreadExecutor()
    private val discoveredMacs = ConcurrentHashMap<String, DiscoveredMacPeer>()
    private val api34Callbacks = ConcurrentHashMap<String, Any>()

    private var registrationListener: NsdManager.RegistrationListener? = null
    private var discoveryListener: NsdManager.DiscoveryListener? = null

    fun start(listenPort: Int) {
        val nsd = nsdManager ?: return
        stop()

        registerLocalService(nsd, listenPort)
        discoverMacHosts(nsd)
    }

    fun stop() {
        val nsd = nsdManager ?: return
        registrationListener?.let { listener ->
            runCatching { nsd.unregisterService(listener) }
        }
        registrationListener = null

        discoveryListener?.let { listener ->
            runCatching { nsd.stopServiceDiscovery(listener) }
        }
        discoveryListener = null

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            api34Callbacks.values.forEach { cb ->
                (cb as? NsdManager.ServiceInfoCallback)?.let { typed ->
                    runCatching { nsd.unregisterServiceInfoCallback(typed) }
                }
            }
        }
        api34Callbacks.clear()
        discoveredMacs.clear()
        onMacsUpdated(emptyList())
    }

    private fun registerLocalService(nsd: NsdManager, listenPort: Int) {
        val info = NsdServiceInfo().apply {
            serviceName = "mirror-${localDeviceId.takeLast(6)}"
            serviceType = SERVICE_TYPE
            port = listenPort
            setAttribute("id", localDeviceId)
            setAttribute("name", localDeviceName)
            setAttribute("model", localModel)
            setAttribute("role", "android")
        }

        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(serviceInfo: NsdServiceInfo) {
                Log.d(TAG, "Registered Continuity NSD: ${serviceInfo.serviceName}:$listenPort")
            }

            override fun onRegistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                Log.w(TAG, "NSD registration failed: $errorCode")
            }

            override fun onServiceUnregistered(serviceInfo: NsdServiceInfo) {}
            override fun onUnregistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {}
        }
        registrationListener = listener
        runCatching { nsd.registerService(info, NsdManager.PROTOCOL_DNS_SD, listener) }
    }

    private fun discoverMacHosts(nsd: NsdManager) {
        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(regType: String) {}

            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                if (serviceInfo.serviceName.contains(localDeviceId.takeLast(6))) return
                resolveMacService(nsd, serviceInfo)
            }

            override fun onServiceLost(serviceInfo: NsdServiceInfo) {
                discoveredMacs.remove(serviceInfo.serviceName)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                    (api34Callbacks.remove(serviceInfo.serviceName) as? NsdManager.ServiceInfoCallback)?.let { cb ->
                        runCatching { nsd.unregisterServiceInfoCallback(cb) }
                    }
                }
                publishMacs()
            }

            override fun onDiscoveryStopped(serviceType: String) {}
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                Log.w(TAG, "NSD start discovery failed: $errorCode")
            }
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
        }
        discoveryListener = listener
        runCatching { nsd.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, listener) }
    }

    private fun resolveMacService(nsd: NsdManager, target: NsdServiceInfo) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            val cb = object : NsdManager.ServiceInfoCallback {
                override fun onServiceInfoCallbackRegistrationFailed(errorCode: Int) {}
                override fun onServiceUpdated(info: NsdServiceInfo) {
                    handleResolvedInfo(info, key = target.serviceName)
                }
                override fun onServiceLost() {
                    discoveredMacs.remove(target.serviceName)
                    publishMacs()
                }
                override fun onServiceInfoCallbackUnregistered() {}
            }
            api34Callbacks[target.serviceName] = cb
            runCatching { nsd.registerServiceInfoCallback(target, callbackExecutor, cb) }
        } else {
            @Suppress("DEPRECATION")
            runCatching {
                nsd.resolveService(target, object : NsdManager.ResolveListener {
                    override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {}
                    override fun onServiceResolved(info: NsdServiceInfo) {
                        handleResolvedInfo(info, key = target.serviceName)
                    }
                })
            }
        }
    }

    private fun handleResolvedInfo(info: NsdServiceInfo, key: String) {
        val attrs = info.attributes
        val role = attrs["role"]?.decodeToString() ?: ""
        val id = attrs["id"]?.decodeToString()?.takeIf { it.isNotBlank() } ?: key
        if (id == localDeviceId || (role.isNotEmpty() && role != "mac")) return

        val name = attrs["name"]?.decodeToString()?.takeIf { it.isNotBlank() } ?: info.serviceName
        val host = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            info.hostAddresses.firstOrNull { it.address.size == 4 }?.hostAddress
                ?: info.hostAddresses.firstOrNull()?.hostAddress
        } else {
            @Suppress("DEPRECATION")
            info.host?.hostAddress
        } ?: return

        if (info.port <= 0) return
        discoveredMacs[key] = DiscoveredMacPeer(id = id, name = name, host = host, port = info.port)
        publishMacs()
    }

    private fun publishMacs() {
        onMacsUpdated(discoveredMacs.values.sortedBy { it.name.lowercase() })
    }

    companion object {
        private const val TAG = "ContinuityNsdHelper"
        const val SERVICE_TYPE = "_mirror-cont._tcp."
    }
}
