package dev.mirror.continuity

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.widget.Toast

/**
 * Android system share target activity (Quick Share / ACTION_SEND).
 * Captures outgoing files or text and streams them to paired Mac.
 */
class ShareTargetActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val intent = intent ?: run {
            finish()
            return
        }

        when (intent.action) {
            Intent.ACTION_SEND -> handleSingleSend(intent)
            Intent.ACTION_SEND_MULTIPLE -> handleMultipleSend(intent)
            else -> finish()
        }
    }

    private fun handleSingleSend(intent: Intent) {
        val uri: Uri? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(Intent.EXTRA_STREAM)
        }

        val text = intent.getStringExtra(Intent.EXTRA_TEXT)

        if (uri != null) {
            dispatchUris(listOf(uri))
        } else if (!text.isNullOrBlank()) {
            dispatchText(text)
        } else {
            finish()
        }
    }

    private fun handleMultipleSend(intent: Intent) {
        val uris = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM)
        }

        if (!uris.isNullOrEmpty()) {
            dispatchUris(uris)
        } else {
            finish()
        }
    }

    private fun dispatchUris(uris: List<Uri>) {
        // Enqueue files into transfer queue via PresenceWakeService or broadcast
        PresenceWakeService.enqueueOutboundTransfer(this, uris)
        Toast.makeText(this, "Sending ${uris.size} item(s) to Mac…", Toast.LENGTH_SHORT).show()
        finish()
    }

    private fun dispatchText(text: String) {
        PresenceWakeService.enqueueOutboundText(this, text)
        Toast.makeText(this, "Sending snippet to Mac…", Toast.LENGTH_SHORT).show()
        finish()
    }
}
