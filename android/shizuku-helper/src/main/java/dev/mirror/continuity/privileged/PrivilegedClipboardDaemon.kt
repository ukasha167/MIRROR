package dev.mirror.continuity.privileged

import android.content.ClipData
import android.content.ClipDescription
import android.net.Uri
import android.os.IBinder
import android.os.Process
import android.util.Log
import java.lang.reflect.InvocationHandler
import java.lang.reflect.Method
import java.lang.reflect.Proxy
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow

/**
 * Clipboard item payload transmitted across the continuity channel.
 */
sealed class OutboundClipItem {
    data class Text(val text: String, val timestamp: Long = System.currentTimeMillis()) : OutboundClipItem()
    data class LazyContentPromise(
        val mimeType: String,
        val contentUri: String,
        val estimatedSizeBytes: Long,
        val label: String? = null,
        val timestamp: Long = System.currentTimeMillis()
    ) : OutboundClipItem()
}

/**
 * Privileged daemon running under UID 2000 (com.android.shell) via app_process or Shizuku.
 *
 * In AOSP ClipboardService, com.android.shell is explicitly permitted to read primary clip
 * in the background, avoiding Android 10+ focus restrictions and eliminating "App pasted from
 * your clipboard" toasts.
 */
class PrivilegedClipboardDaemon(private val isStandaloneProcess: Boolean = false) {

    private val _clipEvents = MutableSharedFlow<OutboundClipItem>(extraBufferCapacity = 32)
    val clipEvents: SharedFlow<OutboundClipItem> = _clipEvents.asSharedFlow()

    private var clipboardProxy: Any? = null
    private var listenerProxy: Any? = null

    /**
     * Attaches to the system clipboard service using reflection on ServiceManager.
     */
    fun startListening(): Boolean {
        return try {
            val uid = Process.myUid()
            Log.i(TAG, "Starting PrivilegedClipboardDaemon under UID=$uid (standalone=$isStandaloneProcess)")

            val serviceManagerClass = Class.forName("android.os.ServiceManager")
            val getServiceMethod = serviceManagerClass.getMethod("getService", String::class.java)
            val binder = getServiceMethod.invoke(null, "clipboard") as? IBinder ?: return false

            val iClipboardStubClass = Class.forName("android.content.IClipboard\$Stub")
            val asInterfaceMethod = iClipboardStubClass.getMethod("asInterface", IBinder::class.java)
            val clipboardService = asInterfaceMethod.invoke(null, binder) ?: return false
            clipboardProxy = clipboardService

            val iOnPrimaryClipChangedListenerClass = Class.forName(
                "android.content.IOnPrimaryClipChangedListener"
            )

            val invocationHandler = InvocationHandler { _, method, _ ->
                if (method.name == "dispatchPrimaryClipChanged") {
                    onPrimaryClipChanged()
                }
                null
            }

            val listener = Proxy.newProxyInstance(
                iOnPrimaryClipChangedListenerClass.classLoader,
                arrayOf(iOnPrimaryClipChangedListenerClass),
                invocationHandler
            )
            listenerProxy = listener

            // Register listener via reflection: addPrimaryClipChangedListener(listener, callingPackage, userId)
            registerListener(clipboardService, listener)
            Log.i(TAG, "Privileged clipboard listener registered successfully for UID $uid")
            true
        } catch (e: Exception) {
            Log.w(TAG, "Failed to register privileged clipboard listener via reflection: ${e.message}")
            false
        }
    }

    private fun registerListener(service: Any, listener: Any) {
        val methods = service.javaClass.methods
        for (m in methods) {
            if (m.name == "addPrimaryClipChangedListener") {
                val paramTypes = m.parameterTypes
                when (paramTypes.size) {
                    1 -> m.invoke(service, listener)
                    2 -> m.invoke(service, listener, SHELL_PACKAGE_NAME)
                    3 -> m.invoke(service, listener, SHELL_PACKAGE_NAME, 0)
                    4 -> m.invoke(service, listener, SHELL_PACKAGE_NAME, null, 0)
                }
                return
            }
        }
    }

    private fun onPrimaryClipChanged() {
        val service = clipboardProxy ?: return
        try {
            val clipData = fetchPrimaryClip(service) ?: return
            val itemCount = clipData.itemCount
            if (itemCount == 0) return

            val item = clipData.getItemAt(0)
            val desc = clipData.description

            if (item.text != null || item.uri == null) {
                val text = item.coerceToText(null)?.toString() ?: return
                if (text.isNotBlank()) {
                    _clipEvents.tryEmit(OutboundClipItem.Text(text))
                    Log.d(TAG, "Emitted privileged clipboard text: ${text.take(30)}...")
                }
            } else if (item.uri != null) {
                val uri = item.uri
                val mime = if (desc.mimeTypeCount > 0) desc.getMimeType(0) else "application/octet-stream"
                val promise = OutboundClipItem.LazyContentPromise(
                    mimeType = mime,
                    contentUri = uri.toString(),
                    estimatedSizeBytes = 0L,
                    label = desc.label?.toString()
                )
                _clipEvents.tryEmit(promise)
                Log.d(TAG, "Emitted lazy content promise for URI: $uri ($mime)")
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error processing primary clip changed event", e)
        }
    }

    private fun fetchPrimaryClip(service: Any): ClipData? {
        val methods = service.javaClass.methods
        for (m in methods) {
            if (m.name == "getPrimaryClip") {
                val paramTypes = m.parameterTypes
                return when (paramTypes.size) {
                    1 -> m.invoke(service, SHELL_PACKAGE_NAME) as? ClipData
                    2 -> m.invoke(service, SHELL_PACKAGE_NAME, 0) as? ClipData
                    3 -> m.invoke(service, SHELL_PACKAGE_NAME, null, 0) as? ClipData
                    else -> null
                }
            }
        }
        return null
    }

    companion object {
        private const val TAG = "PrivClipboardDaemon"
        const val SHELL_PACKAGE_NAME = "com.android.shell"
        const val SHELL_UID = 2000

        /**
         * Standalone main entry point for execution via /system/bin/app_process under UID 2000.
         */
        @JvmStatic
        fun main(args: Array<String>) {
            Log.i(TAG, "Starting standalone PrivilegedClipboardDaemon process")
            val daemon = PrivilegedClipboardDaemon(isStandaloneProcess = true)
            val success = daemon.startListening()
            if (success) {
                // Keep standalone daemon alive on Looper or thread park
                android.os.Looper.prepare()
                android.os.Looper.loop()
            }
        }
    }
}
