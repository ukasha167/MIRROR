//! Hardware resource, battery, and thermal budget monitor for macOS and Android.
//!
//! Enforces the engineering limits from `AGENTS.md` and `plan.md`:
//! - macOS idle RAM `< 28 MB` (`29_360_128` bytes)
//! - macOS idle CPU/GPU `== 0.0%`
//! - macOS 1080p60 mirroring CPU `< 2.5%` on Apple Silicon M1 (`VTDecompressionSession` H.265)
//! - Never default to AV1 on Apple M1 or M2 (lack of hardware AV1 decode engine)
//! - Android idle wakelocks `== 0` and persistent TCP loops `== 0` when away from Mac

use continuity_proto::ThermalState;
use serde::{Deserialize, Serialize};

use crate::error::{CoreError, CoreResult};

/// Maximum permitted idle resident memory on macOS (28 MiB = 29,360,128 bytes).
pub const MAX_MACOS_IDLE_RAM_BYTES: u64 = 28 * 1024 * 1024;

/// Maximum permitted idle CPU percentage on macOS when no streams are active (`0.0%`).
pub const MAX_MACOS_IDLE_CPU_PERCENT: f32 = 0.0;

/// Maximum permitted CPU percentage during 1080p60 H.265 hardware mirroring on Apple M1 (`2.5%`).
pub const MAX_MIRRORING_CPU_PERCENT_M1: f32 = 2.5;

/// Apple Silicon chip generation used to select hardware-accelerated video codecs.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum AppleSiliconGeneration {
    /// Apple M1 / M1 Pro / M1 Max / M1 Ultra (Hardware H.265/H.264; NO hardware AV1 decode).
    M1,
    /// Apple M2 / M2 Pro / M2 Max / M2 Ultra (Hardware H.265/H.264; NO hardware AV1 decode).
    M2,
    /// Apple M3 or newer (Hardware H.265, H.264, and AV1 decode).
    M3OrNewer,
}

/// Video codec selected for `scrcpy-server` mirroring and Continuity Camera streams.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum VideoCodecPreference {
    /// HEVC / H.265 (`VTDecompressionSession` hardware decode on M1/M2/M3+).
    H265,
    /// AVC / H.264 fallback.
    H264,
}

/// Telemetry snapshot of macOS and Android runtime resource consumption.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct ResourceSnapshot {
    /// Current macOS resident set size (RSS) in bytes.
    pub macos_rss_bytes: u64,
    /// Current macOS CPU usage percentage (`0.0..=100.0`).
    pub macos_cpu_percent: f32,
    /// Current macOS GPU usage percentage (`0.0..=100.0`).
    pub macos_gpu_percent: f32,
    /// Whether any mirroring, webcam, or bulk transfer session is currently active.
    pub is_session_active: bool,
    /// Number of held Android `PowerManager.WakeLock` instances while disconnected.
    pub android_idle_wakelocks: u32,
    /// Number of held `WifiManager.MulticastLock` instances while idle.
    pub android_idle_multicast_locks: u32,
}

/// Adaptive stream profile returned when thermal state changes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct StreamThermalBudget {
    /// Target maximum video frame rate (`60`, `30`, or `0` if suspended).
    pub max_fps: u16,
    /// Target maximum video bitrate in bits per second.
    pub max_bitrate_bps: u32,
    /// Whether non-essential background indexing/thumbnails should pause.
    pub pause_background_sync: bool,
}

/// Monitors and validates macOS and Android hardware resource budgets.
#[derive(Debug, Clone)]
pub struct ResourceBudgetMonitor {
    chip_generation: AppleSiliconGeneration,
    last_snapshot: Option<ResourceSnapshot>,
}

impl ResourceBudgetMonitor {
    /// Creates a new monitor configured for the host Mac's Apple Silicon generation.
    pub fn new(chip_generation: AppleSiliconGeneration) -> Self {
        Self {
            chip_generation,
            last_snapshot: None,
        }
    }

    /// Returns the optimal hardware-decoded video codec for the host Mac.
    ///
    /// Per `AGENTS.md`, M1 and M2 Macs lack hardware AV1 decode engines and MUST
    /// use H.265 (`VTDecompressionSession` -> `IOSurface` -> `CAMetalLayer`).
    /// Even on M3+, H.265 remains the default low-latency hardware path.
    pub fn preferred_video_codec(&self) -> VideoCodecPreference {
        match self.chip_generation {
            AppleSiliconGeneration::M1
            | AppleSiliconGeneration::M2
            | AppleSiliconGeneration::M3OrNewer => VideoCodecPreference::H265,
        }
    }

    /// Returns the most recently validated [`ResourceSnapshot`], if any.
    pub fn last_snapshot(&self) -> Option<ResourceSnapshot> {
        self.last_snapshot
    }

    /// Evaluates a [`ResourceSnapshot`] against strict idle and active budgets.
    pub fn verify_snapshot(&mut self, snapshot: ResourceSnapshot) -> CoreResult<()> {
        self.last_snapshot = Some(snapshot);

        if !snapshot.is_session_active {
            if snapshot.macos_rss_bytes > MAX_MACOS_IDLE_RAM_BYTES {
                return Err(CoreError::ResourceBudgetExceeded {
                    metric: "macos_idle_ram_bytes",
                    observed: format!("{} bytes", snapshot.macos_rss_bytes),
                    limit: format!("{MAX_MACOS_IDLE_RAM_BYTES} bytes (28 MiB)"),
                });
            }
            if snapshot.macos_cpu_percent > MAX_MACOS_IDLE_CPU_PERCENT
                || snapshot.macos_gpu_percent > MAX_MACOS_IDLE_CPU_PERCENT
            {
                return Err(CoreError::ResourceBudgetExceeded {
                    metric: "macos_idle_cpu_or_gpu_percent",
                    observed: format!(
                        "cpu={:.2}%, gpu={:.2}%",
                        snapshot.macos_cpu_percent, snapshot.macos_gpu_percent
                    ),
                    limit: "0.00%".to_string(),
                });
            }
            if snapshot.android_idle_wakelocks > 0 || snapshot.android_idle_multicast_locks > 0 {
                return Err(CoreError::ResourceBudgetExceeded {
                    metric: "android_idle_locks",
                    observed: format!(
                        "wakelocks={}, multicast_locks={}",
                        snapshot.android_idle_wakelocks, snapshot.android_idle_multicast_locks
                    ),
                    limit: "0 wakelocks and 0 multicast_locks while idle".to_string(),
                });
            }
        } else if snapshot.macos_cpu_percent > MAX_MIRRORING_CPU_PERCENT_M1 {
            return Err(CoreError::ResourceBudgetExceeded {
                metric: "macos_active_mirroring_cpu_percent",
                observed: format!("{:.2}%", snapshot.macos_cpu_percent),
                limit: format!("{MAX_MIRRORING_CPU_PERCENT_M1:.2}%"),
            });
        }

        Ok(())
    }

    /// Computes the adaptive video/sync budget for a reported [`ThermalState`].
    pub fn compute_thermal_budget(state: ThermalState) -> StreamThermalBudget {
        match state {
            ThermalState::Nominal => StreamThermalBudget {
                max_fps: 60,
                max_bitrate_bps: 8_000_000,
                pause_background_sync: false,
            },
            ThermalState::Fair => StreamThermalBudget {
                max_fps: 60,
                max_bitrate_bps: 5_000_000,
                pause_background_sync: true,
            },
            ThermalState::Serious => StreamThermalBudget {
                max_fps: 30,
                max_bitrate_bps: 3_000_000,
                pause_background_sync: true,
            },
            ThermalState::Critical => StreamThermalBudget {
                max_fps: 0,
                max_bitrate_bps: 0,
                pause_background_sync: true,
            },
        }
    }
}
