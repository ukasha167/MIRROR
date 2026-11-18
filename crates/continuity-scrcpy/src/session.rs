//! `scrcpy-server` v3.x-v5.0 launch command and session configuration builder.

use crate::error::{Result, ScrcpyError};

/// Default path where `scrcpy-server.jar` is pushed on the Android device.
pub const DEFAULT_SERVER_JAR_PATH: &str = "/data/local/tmp/scrcpy-server.jar";
/// Default `scrcpy-server` version string passed as the first `app_process` argument.
pub const DEFAULT_SERVER_VERSION: &str = "3.1";

/// Android `DisplayManager` virtual display flags used by Tier 1 root `FLAG_SECURE` bypass:
/// `VIRTUAL_DISPLAY_FLAG_SECURE (1<<2) | VIRTUAL_DISPLAY_FLAG_SUPPORTS_PROTECTED_BUFFERS (1<<3) | VIRTUAL_DISPLAY_FLAG_TRUSTED (1<<10)`.
pub const ROOT_SECURE_VIRTUAL_DISPLAY_FLAGS: u32 = (1 << 2) | (1 << 3) | (1 << 10);

/// Apple Silicon generation used to select optimal hardware video decode codecs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AppleSiliconChip {
    /// Apple M1 family — hardware H.265/H.264 decode only, NO hardware AV1.
    M1,
    /// Apple M2 family — hardware H.265/H.264 decode only, NO hardware AV1.
    M2,
    /// Apple M3 or M4+ family — includes hardware AV1 decode alongside H.265/H.264.
    M3OrNewer,
}

impl AppleSiliconChip {
    /// Returns `true` if the SoC has a dedicated hardware AV1 decode block in `VideoToolbox`.
    #[must_use]
    pub const fn supports_hardware_av1(self) -> bool {
        matches!(self, Self::M3OrNewer)
    }
}

/// Requested video codec for `scrcpy-server`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VideoCodec {
    /// H.265 / HEVC (`video_codec=h265`). Default for M1/M2 (<2% CPU at 1080p60).
    H265,
    /// H.264 / AVC (`video_codec=h264`). Low-latency universal fallback.
    H264,
    /// AV1 (`video_codec=av1`). Coerced to [`VideoCodec::H265`] on M1/M2 to prevent software decode CPU drain.
    Av1,
}

impl VideoCodec {
    /// Resolves the effective hardware-accelerated codec for the given Mac chip.
    #[must_use]
    pub const fn resolve_for_chip(self, chip: AppleSiliconChip) -> Self {
        match (self, chip.supports_hardware_av1()) {
            (Self::Av1, false) => Self::H265,
            (codec, _) => codec,
        }
    }

    /// Returns the `scrcpy-server` wire parameter value (`"h265"`, `"h264"`, or `"av1"`).
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::H265 => "h265",
            Self::H264 => "h264",
            Self::Av1 => "av1",
        }
    }
}

/// Camera lens selection for Continuity Webcam mode.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CameraFacing {
    /// Front-facing selfie camera (`"front"`).
    Front,
    /// Rear primary/ultrawide camera (`"back"`).
    Back,
    /// External USB camera (`"external"`).
    External,
}

impl CameraFacing {
    /// Returns the `scrcpy` `--camera-facing` string identifier.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self { Self::Front => "front", Self::Back => "back", Self::External => "external" }
    }
}

/// Audio capture source for `scrcpy-server`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AudioSource {
    /// Device internal media output (`"output"`).
    Output,
    /// Hardware acoustic echo-cancelled voice communication microphone (`"mic-voice-communication"`).
    MicVoiceCommunication,
    /// Unprocessed microphone (`"mic-unprocessed"`).
    MicUnprocessed,
}

impl AudioSource {
    /// Returns the `scrcpy` `--audio-source` string value.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Output => "output",
            Self::MicVoiceCommunication => "mic-voice-communication",
            Self::MicUnprocessed => "mic-unprocessed",
        }
    }
}

/// 3-Tier `FLAG_SECURE` handling strategy described in `plan.md` Section 5.4.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FlagSecureTier {
    /// **Tier 1 (Root `su`):** Launches `scrcpy-server` under `UID 0` (`su -c`) with secure display flags.
    Tier1RootSu,
    /// **Tier 2 (LSPosed `DisableFlagSecure`):** Standard `shell` launch with `system_server` hook active.
    Tier2LsposedActive,
    /// **Tier 3 (Non-Root Shell Fallback):** Standard `shell` launch with Accessibility wireframe assist.
    Tier3NonRootAccessibilityWireframe,
}

/// Operating mode for a `scrcpy` streaming session.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SessionMode {
    /// Mirror the primary physical phone display.
    PrimaryDisplay {
        /// Optional maximum dimension cap (e.g. `1920`).
        max_size: Option<u16>,
        /// Turn physical OLED panel off (`SurfaceControl.setDisplayPowerMode(OFF)`) while mirroring.
        turn_screen_off: bool,
    },
    /// Stream an isolated Android app inside a dedicated macOS `NSWindow` via Virtual Display.
    PerAppVirtualDisplay {
        /// Virtual display width in pixels.
        width: u16,
        /// Virtual display height in pixels.
        height: u16,
        /// Virtual display density in DPI.
        dpi: u16,
        /// Target Android package name to launch inside the virtual display.
        package_name: String,
    },
    /// Continuity Webcam & Microphone mode using Android Camera2 hardware H.265 + VoiceComm mic.
    ContinuityWebcam {
        /// Camera capture width in pixels.
        width: u16,
        /// Camera capture height in pixels.
        height: u16,
        /// Target camera framerate (`1..=240`).
        fps: u16,
        /// Selected camera lens (`Front`, `Back`, `External`).
        facing: CameraFacing,
        /// Audio capture source (defaults to [`AudioSource::MicVoiceCommunication`]).
        audio_source: AudioSource,
    },
}

/// Compiled launch plan containing CLI flags, `app_process` server arguments, and full ADB shell command.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScrcpyLaunchPlan {
    /// Resolved hardware-safe video codec (`H265` enforced on M1/M2).
    pub effective_codec: VideoCodec,
    /// Active `FLAG_SECURE` bypass tier.
    pub flag_secure_tier: FlagSecureTier,
    /// Equivalent `scrcpy` v3.x-v5.0 CLI flags.
    pub cli_flags: Vec<String>,
    /// Key-value arguments passed to `com.genymobile.scrcpy.Server`.
    pub server_args: Vec<String>,
    /// Complete command string to execute via `adb shell`.
    pub adb_shell_command: String,
    /// Whether the Mac client should activate the Accessibility wireframe overlay on secure windows.
    pub accessibility_wireframe_enabled: bool,
    /// Virtual display flags mask (`ROOT_SECURE_VIRTUAL_DISPLAY_FLAGS` in Tier 1, `0` otherwise).
    pub virtual_display_flags: u32,
}

/// Builder for constructing validated [`ScrcpyLaunchPlan`] commands across all Continuity modes.
#[derive(Debug, Clone)]
pub struct ScrcpySessionBuilder {
    server_jar_path: String,
    server_version: String,
    scid: u32,
    host_chip: AppleSiliconChip,
    requested_codec: VideoCodec,
    video_bit_rate: u32,
    flag_secure_tier: FlagSecureTier,
    uhid_input: bool,
    mode: SessionMode,
}

impl ScrcpySessionBuilder {
    /// Creates a new session builder defaulting to Apple M1, H.265 (`8 Mbps`), UHID input, and Tier 3 non-root mode.
    #[must_use]
    pub fn new(mode: SessionMode) -> Self {
        Self {
            server_jar_path: DEFAULT_SERVER_JAR_PATH.to_owned(),
            server_version: DEFAULT_SERVER_VERSION.to_owned(),
            scid: 0x1A2B_3C4D,
            host_chip: AppleSiliconChip::M1,
            requested_codec: VideoCodec::H265,
            video_bit_rate: 8_000_000,
            flag_secure_tier: FlagSecureTier::Tier3NonRootAccessibilityWireframe,
            uhid_input: true,
            mode,
        }
    }

    /// Sets the host Mac Apple Silicon generation (M1 and M2 coerce AV1 requests to H.265).
    #[must_use]
    pub const fn host_chip(mut self, chip: AppleSiliconChip) -> Self { self.host_chip = chip; self }

    /// Requests a specific video codec (automatically validated against [`Self::host_chip`]).
    #[must_use]
    pub const fn video_codec(mut self, codec: VideoCodec) -> Self { self.requested_codec = codec; self }

    /// Sets the 31-bit session connection ID (`scid`).
    #[must_use]
    pub const fn scid(mut self, scid: u32) -> Self { self.scid = scid & 0x7FFF_FFFF; self }

    /// Configures the `FLAG_SECURE` bypass tier (Tier 1 Root `su`, Tier 2 LSPosed, Tier 3 Non-Root).
    #[must_use]
    pub const fn flag_secure_tier(mut self, tier: FlagSecureTier) -> Self { self.flag_secure_tier = tier; self }

    /// Enables or disables Linux kernel `/dev/uhid` mouse and keyboard flags (`--mouse=uhid --keyboard=uhid`).
    #[must_use]
    pub const fn uhid_input(mut self, enabled: bool) -> Self { self.uhid_input = enabled; self }

    /// Validates configuration and builds the [`ScrcpyLaunchPlan`].
    pub fn build(&self) -> Result<ScrcpyLaunchPlan> {
        let effective_codec = self.requested_codec.resolve_for_chip(self.host_chip);
        let mut cli_flags = vec![format!("--video-codec={}", effective_codec.as_str())];
        if self.uhid_input {
            cli_flags.push("--mouse=uhid".to_owned());
            cli_flags.push("--keyboard=uhid".to_owned());
        }
        let mut server_args = vec![
            self.server_version.clone(),
            format!("scid={:08x}", self.scid),
            "log_level=info".to_owned(),
            "tunnel_forward=true".to_owned(),
            "send_dummy_byte=true".to_owned(),
            format!("video_codec={}", effective_codec.as_str()),
            format!("video_bit_rate={}", self.video_bit_rate),
        ];

        match &self.mode {
            SessionMode::PrimaryDisplay { max_size, turn_screen_off } => {
                if let Some(max) = max_size {
                    if *max == 0 {
                        return Err(ScrcpyError::InvalidSessionConfig {
                            field: "max_size", reason: "max_size must be greater than 0",
                        });
                    }
                    cli_flags.push(format!("--max-size={max}"));
                    server_args.push(format!("max_size={max}"));
                }
                if *turn_screen_off {
                    cli_flags.push("--turn-screen-off".to_owned());
                    server_args.push("power_off_on_close=false".to_owned());
                    server_args.push("turn_screen_off=true".to_owned());
                }
            }
            SessionMode::PerAppVirtualDisplay { width, height, dpi, package_name } => {
                if *width == 0 || *height == 0 || *dpi == 0 {
                    return Err(ScrcpyError::InvalidDimensions {
                        context: "PerAppVirtualDisplay", offset: 0, width: u32::from(*width), height: u32::from(*height),
                    });
                }
                if package_name.trim().is_empty() {
                    return Err(ScrcpyError::InvalidSessionConfig {
                        field: "package_name", reason: "package_name must not be empty",
                    });
                }
                cli_flags.extend([
                    format!("--new-display={width}x{height}/{dpi}"),
                    format!("--start-app={package_name}"),
                    "--no-vd-destroy-content".to_owned(),
                    "--no-vd-system-decorations".to_owned(),
                    "--display-ime-policy=local".to_owned(),
                    "--flex-display".to_owned(),
                ]);
                server_args.extend([
                    format!("new_display={width}x{height}/{dpi}"),
                    format!("start_app={package_name}"),
                    "vd_destroy_content=false".to_owned(),
                    "vd_system_decorations=false".to_owned(),
                    "display_ime_policy=local".to_owned(),
                    "flex_display=true".to_owned(),
                ]);
            }
            SessionMode::ContinuityWebcam { width, height, fps, facing, audio_source } => {
                if *width == 0 || *height == 0 {
                    return Err(ScrcpyError::InvalidDimensions {
                        context: "ContinuityWebcam", offset: 0, width: u32::from(*width), height: u32::from(*height),
                    });
                }
                if *fps == 0 || *fps > 240 {
                    return Err(ScrcpyError::InvalidSessionConfig {
                        field: "fps", reason: "camera fps must be in 1..=240",
                    });
                }
                cli_flags.extend([
                    "--video-source=camera".to_owned(),
                    format!("--camera-size={width}x{height}"),
                    format!("--camera-fps={fps}"),
                    format!("--camera-facing={}", facing.as_str()),
                    format!("--audio-source={}", audio_source.as_str()),
                ]);
                server_args.extend([
                    "video_source=camera".to_owned(),
                    format!("camera_size={width}x{height}"),
                    format!("camera_fps={fps}"),
                    format!("camera_facing={}", facing.as_str()),
                    format!("audio_source={}", audio_source.as_str()),
                    "control=false".to_owned(),
                ]);
            }
        }

        let (adb_shell_command, accessibility_wireframe_enabled, virtual_display_flags) =
            match self.flag_secure_tier {
                FlagSecureTier::Tier1RootSu => {
                    server_args.push("secure_display=true".to_owned());
                    server_args.push(format!("virtual_display_flags=0x{ROOT_SECURE_VIRTUAL_DISPLAY_FLAGS:04x}"));
                    let cmd = format!(
                        "su -c \"CLASSPATH={} app_process / com.genymobile.scrcpy.Server {}\"",
                        self.server_jar_path, server_args.join(" ")
                    );
                    (cmd, false, ROOT_SECURE_VIRTUAL_DISPLAY_FLAGS)
                }
                FlagSecureTier::Tier2LsposedActive => {
                    server_args.push("lsposed_disable_flag_secure=active".to_owned());
                    let cmd = format!(
                        "CLASSPATH={} app_process / com.genymobile.scrcpy.Server {}",
                        self.server_jar_path, server_args.join(" ")
                    );
                    (cmd, false, 0)
                }
                FlagSecureTier::Tier3NonRootAccessibilityWireframe => {
                    server_args.push("accessibility_wireframe=true".to_owned());
                    let cmd = format!(
                        "CLASSPATH={} app_process / com.genymobile.scrcpy.Server {}",
                        self.server_jar_path, server_args.join(" ")
                    );
                    (cmd, true, 0)
                }
            };
        Ok(ScrcpyLaunchPlan {
            effective_codec, flag_secure_tier: self.flag_secure_tier, cli_flags, server_args,
            adb_shell_command, accessibility_wireframe_enabled, virtual_display_flags,
        })
    }
}
