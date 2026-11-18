package dev.mirror.continuity.privileged

/**
 * 3-Tier FLAG_SECURE bypass levels as specified in plan.md Section 5.4.
 */
enum class FlagSecureTier(val tierNumber: Int, val description: String) {
    /**
     * Tier 1: Zero-modification / rooted scrcpy-server launch via su (UID 0).
     * Passes secure=true to SurfaceControl.createDisplay() and sets
     * VIRTUAL_DISPLAY_FLAG_SECURE | VIRTUAL_DISPLAY_FLAG_SUPPORTS_PROTECTED_BUFFERS.
     */
    TIER_1_ROOT_SU(
        tierNumber = 1,
        description = "Root (su) UID 0 SurfaceControl secure display composition"
    ),

    /**
     * Tier 2: LSPosed / Zygisk DisableFlagSecure system_server hook active.
     * Hooks WindowState.isSecureLocked() -> false and suppresses screenshot/record callbacks.
     */
    TIER_2_LSPOSED(
        tierNumber = 2,
        description = "LSPosed / Zygisk DisableFlagSecure system_server hook"
    ),

    /**
     * Tier 3: Non-root UID 2000 shell / Shizuku fallback.
     * Pixels are blanked by SurfaceFlinger, but touch/keyboard injection works,
     * augmented with Accessibility wireframe node bounding-boxes.
     */
    TIER_3_SHELL_ACCESSIBILITY(
        tierNumber = 3,
        description = "Non-root shell (UID 2000) with Accessibility wireframe assist"
    )
}
