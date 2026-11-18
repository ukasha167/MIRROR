package dev.mirror.continuity.privileged

import android.content.ClipData
import android.content.ClipDescription
import android.net.Uri
import android.util.Log
import android.view.DragEvent
import android.view.View
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow

/**
 * Data extracted from an active global drag-and-drop session on Android.
 */
data class DragPayloadItem(
    val uriString: String? = null,
    val text: String? = null,
    val mimeType: String,
    val label: String? = null
)

/**
 * Encapsulates global drag session metadata to forward to macOS NSFilePromiseProvider.
 */
data class GlobalDragOffer(
    val items: List<DragPayloadItem>,
    val flags: Int,
    val initialX: Float,
    val initialY: Float,
    val isGlobal: Boolean,
    val isUriReadGranted: Boolean,
    val timestamp: Long = System.currentTimeMillis()
)

/**
 * Intercepts Android View.startDragAndDrop operations holding DRAG_FLAG_GLOBAL (0x100)
 * and DRAG_FLAG_GLOBAL_URI_READ (0x1).
 *
 * When an Android user long-presses an item in Google Photos, Gallery, or Files and drags,
 * this interceptor captures the ClipData content:// URIs and notifies the Mac client over
 * the control channel so dragging across the window edge into macOS Finder triggers an
 * NSFilePromiseProvider pull.
 */
class GlobalDragInterceptor : View.OnDragListener {

    private val _dragOffers = MutableSharedFlow<GlobalDragOffer>(extraBufferCapacity = 16)
    val dragOffers: SharedFlow<GlobalDragOffer> = _dragOffers.asSharedFlow()

    private var activeDragOffer: GlobalDragOffer? = null

    override fun onDrag(v: View, event: DragEvent): Boolean {
        when (event.action) {
            DragEvent.ACTION_DRAG_STARTED -> {
                val clipDesc = event.clipDescription ?: return false
                val clipData = event.clipData

                val flags = extractDragFlags(event)
                val isGlobal = (flags and DRAG_FLAG_GLOBAL) != 0
                val isUriRead = (flags and DRAG_FLAG_GLOBAL_URI_READ) != 0

                val payloadItems = parseClipData(clipData, clipDesc)
                if (payloadItems.isNotEmpty()) {
                    val offer = GlobalDragOffer(
                        items = payloadItems,
                        flags = flags,
                        initialX = event.x,
                        initialY = event.y,
                        isGlobal = isGlobal,
                        isUriReadGranted = isUriRead
                    )
                    activeDragOffer = offer
                    _dragOffers.tryEmit(offer)
                    Log.i(TAG, "Captured global drag started: ${payloadItems.size} items, global=$isGlobal")
                    return true
                }
            }
            DragEvent.ACTION_DRAG_LOCATION -> {
                // Tracking coordinates as user approaches edge of mirrored display
            }
            DragEvent.ACTION_DRAG_ENDED -> {
                Log.d(TAG, "Global drag session ended")
                activeDragOffer = null
            }
        }
        return false
    }

    fun parseClipData(clipData: ClipData?, clipDesc: ClipDescription): List<DragPayloadItem> {
        val result = mutableListOf<DragPayloadItem>()
        if (clipData != null) {
            val count = clipData.itemCount
            for (i in 0 until count) {
                val item = clipData.getItemAt(i)
                val mime = if (clipDesc.mimeTypeCount > i) {
                    clipDesc.getMimeType(i)
                } else if (clipDesc.mimeTypeCount > 0) {
                    clipDesc.getMimeType(0)
                } else {
                    "application/octet-stream"
                }

                result.add(
                    DragPayloadItem(
                        uriString = item.uri?.toString(),
                        text = item.text?.toString(),
                        mimeType = mime,
                        label = clipDesc.label?.toString()
                    )
                )
            }
        } else if (clipDesc.mimeTypeCount > 0) {
            result.add(
                DragPayloadItem(
                    uriString = null,
                    text = null,
                    mimeType = clipDesc.getMimeType(0),
                    label = clipDesc.label?.toString()
                )
            )
        }
        return result
    }

    private fun extractDragFlags(event: DragEvent): Int {
        // Drag flags are passed via View.startDragAndDrop(data, shadow, myLocalState, flags)
        // In system drag dispatcher, flags are stored in private mFlags field or local state.
        return try {
            val field = event.javaClass.getDeclaredField("mFlags")
            field.isAccessible = true
            field.getInt(event)
        } catch (_: Exception) {
            // Default assumed flags when global drag is initiated
            DRAG_FLAG_GLOBAL or DRAG_FLAG_GLOBAL_URI_READ
        }
    }

    companion object {
        private const val TAG = "GlobalDragInterceptor"

        const val DRAG_FLAG_GLOBAL = 0x00000100
        const val DRAG_FLAG_GLOBAL_URI_READ = 0x00000001
        const val DRAG_FLAG_GLOBAL_URI_WRITE = 0x00000002

        fun isGlobalDrag(flags: Int): Boolean = (flags and DRAG_FLAG_GLOBAL) != 0
        fun hasUriReadPermission(flags: Int): Boolean = (flags and DRAG_FLAG_GLOBAL_URI_READ) != 0
    }
}
