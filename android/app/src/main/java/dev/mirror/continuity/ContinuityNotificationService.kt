package dev.mirror.continuity

import android.app.Notification
import android.app.RemoteInput
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow

/**
 * Mirrored notification representation for transmission to macOS.
 */
data class MirroredNotification(
    val key: String,
    val packageName: String,
    val title: String?,
    val text: String?,
    val timestamp: Long,
    val isClearable: Boolean,
    val replyActionTitle: String? = null
)

/**
 * 2FA One-Time Password payload extracted from notification or SMS.
 */
data class ExtractedOtp(
    val code: String,
    val senderPackage: String,
    val rawSnippet: String,
    val timestamp: Long = System.currentTimeMillis()
)

/**
 * Pure-Kotlin 2FA OTP Extractor with regex and validation heuristics.
 * Decoupled from Android framework for deterministic hardware-free unit testing.
 */
object OtpExtractor {

    private val OTP_KEYWORDS = listOf(
        "code", "otp", "pin", "código", "codigo", "verificación", "verificacion",
        "verification", "verify", "passcode", "secret", "authentication", "auth",
        "one-time"
    )

    // Regex for prefixed formats like "G-123456" or hyphenated "123-456"
    private val PREFIXED_OTP_REGEX = Regex(
        """(?i)\b([A-Z]-?[0-9]{5,7}|[0-9]{3}-[0-9]{3,4})\b"""
    )

    // Regex for standalone 4-8 digit numeric codes
    private val DIGIT_TOKEN_REGEX = Regex("""\b([0-9]{4,8})\b""")

    // Heuristic exclusions: Years (1990-2035)
    private val YEAR_EXCLUSION_REGEX = Regex("""^(?:19\d{2}|20[0-3]\d)$""")

    fun extract(text: String?, senderPackage: String = ""): ExtractedOtp? {
        if (text.isNullOrBlank()) return null

        // 1. Try prefixed format (e.g. G-928172, 482-910)
        PREFIXED_OTP_REGEX.find(text)?.let { match ->
            val candidate = match.groupValues[1].replace("-", "")
            val cleanCode = if (candidate.startsWith("G", ignoreCase = true)) candidate.substring(1) else candidate
            if (isValidCandidate(cleanCode, text)) {
                return ExtractedOtp(cleanCode, senderPackage, text)
            }
        }

        // 2. Check if text contains any OTP keyword
        val lowerText = text.lowercase()
        val hasKeyword = OTP_KEYWORDS.any { lowerText.contains(it) }

        if (hasKeyword) {
            for (match in DIGIT_TOKEN_REGEX.findAll(text)) {
                val candidate = match.groupValues[1]
                if (isValidCandidate(candidate, text)) {
                    return ExtractedOtp(candidate, senderPackage, text)
                }
            }
        }

        return null
    }

    private fun isValidCandidate(code: String, fullText: String): Boolean {
        // Exclude 4-digit years unless explicitly in OTP context
        if (code.length == 4 && YEAR_EXCLUSION_REGEX.matches(code)) {
            val lower = fullText.lowercase()
            if (!lower.contains("code") && !lower.contains("pin") && !lower.contains("otp")) {
                return false
            }
        }
        // Exclude currency like "$2500" or trailing units
        val idx = fullText.indexOf(code)
        if (idx > 0 && (fullText[idx - 1] == '$' || fullText[idx - 1] == '€' || fullText[idx - 1] == '£')) {
            return false
        }
        if (fullText.contains("$code USD") || fullText.contains("$code EUR")) {
            return false
        }
        return code.length in 4..8
    }
}

/**
 * NotificationListenerService that mirrors notifications, extracts 2FA OTP codes,
 * and executes inline RemoteInput replies on behalf of macOS.
 */
class ContinuityNotificationService : NotificationListenerService() {

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        super.onNotificationPosted(sbn)
        sbn ?: return

        val extras = sbn.notification.extras
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString()
        val text = extras.getCharSequence(Notification.EXTRA_TEXT)?.toString()
            ?: extras.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString()

        val fullBody = listOfNotNull(title, text).joinToString(" ")

        // Check for 2FA OTP code
        val otp = OtpExtractor.extract(fullBody, sbn.packageName)
        if (otp != null) {
            Log.i(TAG, "Extracted 2FA OTP code: [REDACTED ${otp.code.length} digits] from ${sbn.packageName}")
            _otpFlow.tryEmit(otp)
        }

        // Find inline reply action title if available
        val replyAction = findReplyAction(sbn.notification)

        val mirrored = MirroredNotification(
            key = sbn.key,
            packageName = sbn.packageName,
            title = title,
            text = text,
            timestamp = sbn.postTime,
            isClearable = sbn.isClearable,
            replyActionTitle = replyAction?.title?.toString()
        )

        _notificationFlow.tryEmit(mirrored)
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification?) {
        super.onNotificationRemoved(sbn)
        sbn ?: return
        _removedNotificationKeyFlow.tryEmit(sbn.key)
    }

    /**
     * Executes an inline reply using RemoteInput on an active notification.
     */
    fun sendInlineReply(notificationKey: String, replyText: String): Boolean {
        val sbn = activeNotifications?.find { it.key == notificationKey } ?: return false
        val notification = sbn.notification
        val action = findReplyAction(notification) ?: return false

        val remoteInputs = action.remoteInputs ?: return false
        val replyIntent = Intent()
        val bundle = Bundle()

        for (input in remoteInputs) {
            bundle.putCharSequence(input.resultKey, replyText)
        }
        RemoteInput.addResultsToIntent(remoteInputs, replyIntent, bundle)

        return try {
            action.actionIntent.send(this, 0, replyIntent)
            Log.i(TAG, "Successfully executed RemoteInput inline reply for $notificationKey")
            true
        } catch (e: Exception) {
            Log.e(TAG, "Failed sending inline reply intent", e)
            false
        }
    }

    private fun findReplyAction(notification: Notification): Notification.Action? {
        val actions = notification.actions ?: return null
        for (action in actions) {
            val remoteInputs = action.remoteInputs ?: continue
            for (input in remoteInputs) {
                if (input.allowFreeFormInput) {
                    return action
                }
            }
        }
        return null
    }

    companion object {
        private const val TAG = "ContinuityNotif"

        private val _notificationFlow = MutableSharedFlow<MirroredNotification>(extraBufferCapacity = 64)
        val notificationFlow: SharedFlow<MirroredNotification> = _notificationFlow.asSharedFlow()

        private val _removedNotificationKeyFlow = MutableSharedFlow<String>(extraBufferCapacity = 64)
        val removedNotificationKeyFlow: SharedFlow<String> = _removedNotificationKeyFlow.asSharedFlow()

        private val _otpFlow = MutableSharedFlow<ExtractedOtp>(extraBufferCapacity = 16)
        val otpFlow: SharedFlow<ExtractedOtp> = _otpFlow.asSharedFlow()
    }
}
