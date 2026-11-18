package dev.mirror.continuity.privileged

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests validating clipboard models and drag flag calculations.
 */
class PrivilegedClipboardDaemonTest {

    @Test
    fun testTextPayloadModel() {
        val payload = OutboundClipItem.Text("https://github.com")
        assertEquals("https://github.com", payload.text)
        assertTrue(payload.timestamp > 0)
    }

    @Test
    fun testLazyContentPromiseModel() {
        val promise = OutboundClipItem.LazyContentPromise(
            mimeType = "image/png",
            contentUri = "content://media/external/images/media/42",
            estimatedSizeBytes = 1024 * 1024,
            label = "Screenshot"
        )

        assertEquals("image/png", promise.mimeType)
        assertEquals("content://media/external/images/media/42", promise.contentUri)
        assertEquals("Screenshot", promise.label)
    }

    @Test
    fun testGlobalDragFlagChecks() {
        val globalReadFlags = GlobalDragInterceptor.DRAG_FLAG_GLOBAL or
                GlobalDragInterceptor.DRAG_FLAG_GLOBAL_URI_READ

        assertTrue(GlobalDragInterceptor.isGlobalDrag(globalReadFlags))
        assertTrue(GlobalDragInterceptor.hasUriReadPermission(globalReadFlags))

        val localFlags = 0
        assertFalse(GlobalDragInterceptor.isGlobalDrag(localFlags))
        assertFalse(GlobalDragInterceptor.hasUriReadPermission(localFlags))
    }
}
