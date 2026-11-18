package dev.mirror.continuity

import android.content.ComponentName
import android.content.Context
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.os.Handler
import android.os.Looper
import android.util.Log
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Track metadata synchronized to macOS MPNowPlayingInfoCenter.
 */
data class MediaTrackInfo(
    val title: String = "",
    val artist: String = "",
    val album: String = "",
    val durationMs: Long = 0L,
    val packageName: String = "",
    val hasArtwork: Boolean = false
)

/**
 * Playback state synchronized to macOS player controls.
 */
data class MediaPlaybackInfo(
    val isPlaying: Boolean = false,
    val positionMs: Long = 0L,
    val playbackSpeed: Float = 1.0f,
    val canSkipNext: Boolean = true,
    val canSkipPrevious: Boolean = true
)

/**
 * Manages Android active MediaSessions, streaming metadata and playback status
 * to Mac, and executing incoming remote playback control commands.
 */
class MediaSessionSync(private val context: Context) {

    private val sessionManager = context.getSystemService(Context.MEDIA_SESSION_SERVICE) as? MediaSessionManager
    private val mainHandler = Handler(Looper.getMainLooper())

    private var activeController: MediaController? = null

    private val _currentTrackFlow = MutableStateFlow(MediaTrackInfo())
    val currentTrackFlow: StateFlow<MediaTrackInfo> = _currentTrackFlow.asStateFlow()

    private val _playbackStateFlow = MutableStateFlow(MediaPlaybackInfo())
    val playbackStateFlow: StateFlow<MediaPlaybackInfo> = _playbackStateFlow.asStateFlow()

    private val controllerCallback = object : MediaController.Callback() {
        override fun onMetadataChanged(metadata: MediaMetadata?) {
            updateTrackMetadata(metadata, activeController?.packageName ?: "")
        }

        override fun onPlaybackStateChanged(state: PlaybackState?) {
            updatePlaybackState(state)
        }

        override fun onSessionDestroyed() {
            Log.d(TAG, "Active media session destroyed")
            activeController = null
            _currentTrackFlow.value = MediaTrackInfo()
            _playbackStateFlow.value = MediaPlaybackInfo()
        }
    }

    private val sessionListener = MediaSessionManager.OnActiveSessionsChangedListener { controllers ->
        val newPrimary = controllers?.firstOrNull()
        if (newPrimary?.sessionToken != activeController?.sessionToken) {
            attachController(newPrimary)
        }
    }

    /**
     * Start observing active media sessions. Requires NotificationListener permission.
     */
    fun startObserving(listenerComponent: ComponentName) {
        val manager = sessionManager ?: return
        try {
            manager.addOnActiveSessionsChangedListener(sessionListener, listenerComponent, mainHandler)
            val initial = manager.getActiveSessions(listenerComponent)
            attachController(initial.firstOrNull())
            Log.i(TAG, "Started observing MediaSession changes")
        } catch (e: SecurityException) {
            Log.w(TAG, "Missing BIND_NOTIFICATION_LISTENER_SERVICE for MediaSessionManager", e)
        }
    }

    fun stopObserving() {
        sessionManager?.removeOnActiveSessionsChangedListener(sessionListener)
        activeController?.unregisterCallback(controllerCallback)
        activeController = null
        Log.i(TAG, "Stopped observing MediaSession changes")
    }

    private fun attachController(controller: MediaController?) {
        activeController?.unregisterCallback(controllerCallback)
        activeController = controller

        if (controller != null) {
            controller.registerCallback(controllerCallback, mainHandler)
            updateTrackMetadata(controller.metadata, controller.packageName)
            updatePlaybackState(controller.playbackState)
            Log.i(TAG, "Attached to media session: ${controller.packageName}")
        } else {
            _currentTrackFlow.value = MediaTrackInfo()
            _playbackStateFlow.value = MediaPlaybackInfo()
        }
    }

    private fun updateTrackMetadata(metadata: MediaMetadata?, packageName: String) {
        if (metadata == null) {
            _currentTrackFlow.value = MediaTrackInfo(packageName = packageName)
            return
        }

        val title = metadata.getString(MediaMetadata.METADATA_KEY_TITLE)
            ?: metadata.getString(MediaMetadata.METADATA_KEY_DISPLAY_TITLE)
            ?: "Unknown Title"

        val artist = metadata.getString(MediaMetadata.METADATA_KEY_ARTIST)
            ?: metadata.getString(MediaMetadata.METADATA_KEY_ALBUM_ARTIST)
            ?: "Unknown Artist"

        val album = metadata.getString(MediaMetadata.METADATA_KEY_ALBUM) ?: ""
        val duration = metadata.getLong(MediaMetadata.METADATA_KEY_DURATION)
        val hasArt = metadata.getBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART) != null ||
                metadata.getBitmap(MediaMetadata.METADATA_KEY_ART) != null

        _currentTrackFlow.value = MediaTrackInfo(
            title = title,
            artist = artist,
            album = album,
            durationMs = if (duration > 0) duration else 0L,
            packageName = packageName,
            hasArtwork = hasArt
        )
    }

    private fun updatePlaybackState(state: PlaybackState?) {
        if (state == null) {
            _playbackStateFlow.value = MediaPlaybackInfo()
            return
        }

        val isPlaying = state.state == PlaybackState.STATE_PLAYING
        val actions = state.actions

        _playbackStateFlow.value = MediaPlaybackInfo(
            isPlaying = isPlaying,
            positionMs = state.position,
            playbackSpeed = state.playbackSpeed,
            canSkipNext = (actions and PlaybackState.ACTION_SKIP_TO_NEXT) != 0L,
            canSkipPrevious = (actions and PlaybackState.ACTION_SKIP_TO_PREVIOUS) != 0L
        )
    }

    // --- Inbound Remote Commands from macOS ---

    fun dispatchPlay() {
        activeController?.transportControls?.play()
    }

    fun dispatchPause() {
        activeController?.transportControls?.pause()
    }

    fun dispatchSkipNext() {
        activeController?.transportControls?.skipToNext()
    }

    fun dispatchSkipPrevious() {
        activeController?.transportControls?.skipToPrevious()
    }

    fun dispatchSeekTo(positionMs: Long) {
        activeController?.transportControls?.seekTo(positionMs)
    }

    companion object {
        private const val TAG = "MediaSessionSync"
    }
}
