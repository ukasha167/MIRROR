package dev.mirror.continuity.privileged

import android.content.Context
import android.os.Build
import android.util.Log
import java.io.File

/**
 * Launch configuration for scrcpy-server.
 */
data class ScrcpyLaunchConfig(
    val serverJarPath: String = "/data/local/tmp/scrcpy-server.jar",
    val videoCodec: String = "h265", // H.265 hardware decoded by Apple M1 VideoToolbox
    val bitRate: Int = 8_000_000,
    val maxFps: Int = 60,
    val maxSize: Int = 1920,
    val turnScreenOff: Boolean = true,
    val stayAwake: Boolean = false,
    val audioSource: String = "playback", // or "mic-voice-communication" for webcam
    val videoSource: String = "display",  // or "camera"
    val cameraFacing: String? = null,
    val virtualDisplaySpec: String? = null, // e.g. "1280x800/160"
    val startAppPackage: String? = null
)

/**
 * Manages scrcpy-server launch strategies across the 3 FLAG_SECURE bypass tiers.
 */
class ScrcpyLauncher(private val context: Context? = null) {

    /**
     * Probes device capabilities to select the optimal FLAG_SECURE tier.
     */
    fun detectOptimalTier(
        suPathOverride: String? = null,
        isLsposedOverride: Boolean? = null
    ): FlagSecureTier {
        if (isLsposedOverride == true || isLsposedActive()) {
            Log.i(TAG, "Selected Tier 2: LSPosed / DisableFlagSecure active")
            return FlagSecureTier.TIER_2_LSPOSED
        }

        if (suPathOverride != null || hasRootSu()) {
            Log.i(TAG, "Selected Tier 1: Root (su) available")
            return FlagSecureTier.TIER_1_ROOT_SU
        }

        Log.i(TAG, "Selected Tier 3: Non-root shell with Accessibility wireframe fallback")
        return FlagSecureTier.TIER_3_SHELL_ACCESSIBILITY
    }

    /**
     * Builds the execution command line string for spawning scrcpy-server.
     */
    fun buildLaunchCommand(
        tier: FlagSecureTier,
        config: ScrcpyLaunchConfig = ScrcpyLaunchConfig()
    ): String {
        val args = mutableListOf<String>()

        // Version & control parameters
        args.add("scrcpy_version=3.1")
        args.add("log_level=info")
        args.add("video_codec=${config.videoCodec}")
        args.add("video_bit_rate=${config.bitRate}")
        args.add("max_fps=${config.maxFps}")
        args.add("max_size=${config.maxSize}")

        // Battery optimization: physical OLED screen off
        if (config.turnScreenOff) {
            args.add("power_off_on_close=false")
            args.add("turn_screen_off=true")
        }

        // Camera streaming mode for macOS Continuity Camera
        if (config.videoSource == "camera") {
            args.add("video_source=camera")
            config.cameraFacing?.let { args.add("camera_facing=$it") }
            args.add("audio_source=mic-voice-communication")
        } else {
            args.add("video_source=display")
            args.add("audio_source=${config.audioSource}")
        }

        // Per-app virtual display window streaming
        if (!config.virtualDisplaySpec.isNullOrBlank()) {
            args.add("new_display=${config.virtualDisplaySpec}")
            args.add("flex_display=true")
            args.add("no_vd_destroy_content=true")
            config.startAppPackage?.let { args.add("start_app=$it") }
        }

        // Tier-specific FLAG_SECURE options
        when (tier) {
            FlagSecureTier.TIER_1_ROOT_SU -> {
                // Patched scrcpy-server: secure=true in SurfaceControl.createDisplay
                args.add("secure_display=true")
                val classpath = "CLASSPATH=${config.serverJarPath}"
                val cmd = "$classpath app_process / com.genymobile.scrcpy.Server ${args.joinToString(" ")}"
                return "su -c \"$cmd\""
            }
            FlagSecureTier.TIER_2_LSPOSED -> {
                args.add("secure_display=false") // system_server hooks already strip FLAG_SECURE
                val classpath = "CLASSPATH=${config.serverJarPath}"
                return "$classpath app_process / com.genymobile.scrcpy.Server ${args.joinToString(" ")}"
            }
            FlagSecureTier.TIER_3_SHELL_ACCESSIBILITY -> {
                args.add("secure_display=false")
                args.add("accessibility_wireframe=true") // Fallback UI node bounding box overlay
                val classpath = "CLASSPATH=${config.serverJarPath}"
                return "$classpath app_process / com.genymobile.scrcpy.Server ${args.joinToString(" ")}"
            }
        }
    }

    private fun hasRootSu(): Boolean {
        val paths = arrayOf(
            "/system/bin/su",
            "/system/xbin/su",
            "/sbin/su",
            "/system/sd/xbin/su",
            "/data/local/xbin/su",
            "/data/local/bin/su",
            "/data/local/su"
        )
        return paths.any { File(it).exists() }
    }

    private fun isLsposedActive(): Boolean {
        val indicators = arrayOf(
            File("/data/adb/lspd"),
            File("/data/adb/modules/zygisk_lsposed"),
            File("/data/adb/modules/riru_lsposed")
        )
        return indicators.any { it.exists() }
    }

    companion object {
        private const val TAG = "ScrcpyLauncher"
    }
}
