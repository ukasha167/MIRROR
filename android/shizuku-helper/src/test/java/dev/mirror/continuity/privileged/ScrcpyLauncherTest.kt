package dev.mirror.continuity.privileged

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests validating ScrcpyLauncher command synthesis and FLAG_SECURE tier options.
 */
class ScrcpyLauncherTest {

    private val launcher = ScrcpyLauncher()

    @Test
    fun testTier1RootSuCommandGeneration() {
        val cmd = launcher.buildLaunchCommand(
            tier = FlagSecureTier.TIER_1_ROOT_SU,
            config = ScrcpyLaunchConfig()
        )

        assertTrue(cmd.startsWith("su -c \""))
        assertTrue(cmd.contains("video_codec=h265"))
        assertTrue(cmd.contains("turn_screen_off=true"))
        assertTrue(cmd.contains("secure_display=true"))
    }

    @Test
    fun testTier2LsposedCommandGeneration() {
        val cmd = launcher.buildLaunchCommand(
            tier = FlagSecureTier.TIER_2_LSPOSED,
            config = ScrcpyLaunchConfig()
        )

        assertTrue(cmd.startsWith("CLASSPATH=/data/local/tmp/scrcpy-server.jar"))
        assertTrue(cmd.contains("secure_display=false"))
        assertTrue(cmd.contains("video_codec=h265"))
    }

    @Test
    fun testTier3ShellAccessibilityCommandGeneration() {
        val cmd = launcher.buildLaunchCommand(
            tier = FlagSecureTier.TIER_3_SHELL_ACCESSIBILITY,
            config = ScrcpyLaunchConfig()
        )

        assertTrue(cmd.contains("secure_display=false"))
        assertTrue(cmd.contains("accessibility_wireframe=true"))
    }

    @Test
    fun testCameraWebcamModeArgs() {
        val config = ScrcpyLaunchConfig(
            videoSource = "camera",
            cameraFacing = "back"
        )
        val cmd = launcher.buildLaunchCommand(FlagSecureTier.TIER_2_LSPOSED, config)

        assertTrue(cmd.contains("video_source=camera"))
        assertTrue(cmd.contains("camera_facing=back"))
        assertTrue(cmd.contains("audio_source=mic-voice-communication"))
    }

    @Test
    fun testPerAppVirtualDisplayArgs() {
        val config = ScrcpyLaunchConfig(
            virtualDisplaySpec = "1920x1080/320",
            startAppPackage = "com.whatsapp"
        )
        val cmd = launcher.buildLaunchCommand(FlagSecureTier.TIER_2_LSPOSED, config)

        assertTrue(cmd.contains("new_display=1920x1080/320"))
        assertTrue(cmd.contains("flex_display=true"))
        assertTrue(cmd.contains("start_app=com.whatsapp"))
    }

    @Test
    fun testTierOverrideDetection() {
        val tierLsposed = launcher.detectOptimalTier(isLsposedOverride = true)
        assertEquals(FlagSecureTier.TIER_2_LSPOSED, tierLsposed)

        val tierRoot = launcher.detectOptimalTier(suPathOverride = "/system/bin/su", isLsposedOverride = false)
        assertEquals(FlagSecureTier.TIER_1_ROOT_SU, tierRoot)
    }
}
