//! Typed error hierarchy for `continuity-core` and its UniFFI facade.

use continuity_proto::ProtoError;
use thiserror::Error;

/// Errors returned by `continuity-core` operations.
#[derive(Debug, Error, Clone, PartialEq, Eq)]
pub enum CoreError {
    /// Underlying wire protocol or pairing error from `continuity-proto`.
    #[error("protocol error: {0}")]
    Proto(#[from] ProtoError),

    /// Platform Keychain (macOS) or Keystore (Android) operation failed.
    #[error("keystore bridge error during '{operation}': {reason}")]
    Keystore {
        /// Keystore method name.
        operation: &'static str,
        /// Error detail returned by the platform bridge.
        reason: String,
    },

    /// Attempted a zero-prompt continuity operation with an unpaired device.
    #[error("device '{device_id}' is not paired in the trusted device store")]
    DeviceNotPaired {
        /// Untrusted device identifier.
        device_id: String,
    },

    /// Clipboard offer was rejected by 1Password / Maccy pasteboard privacy rules.
    #[error(
        "clipboard offer {offer_id} blocked by privacy policy (concealed={is_concealed}, transient={is_transient})"
    )]
    ClipboardPrivacyBlocked {
        /// Offer identifier.
        offer_id: u64,
        /// Whether `org.nspasteboard.ConcealedType` / `EXTRA_IS_SENSITIVE` was set.
        is_concealed: bool,
        /// Whether `org.nspasteboard.TransientType` was set.
        is_transient: bool,
    },

    /// Resource consumption exceeded the strict idle or active hardware budget.
    #[error("resource budget violation on {metric}: observed {observed}, limit {limit}")]
    ResourceBudgetExceeded {
        /// Metric name (`"macos_idle_ram_bytes"`, `"macos_idle_cpu_pct"`, etc.).
        metric: &'static str,
        /// Observed value formatted with units.
        observed: String,
        /// Maximum permitted value formatted with units.
        limit: String,
    },

    /// Referenced lazy clipboard or drag-out offer ID does not exist.
    #[error("active offer {offer_id} not found in multiplexer state")]
    OfferNotFound {
        /// Missing offer identifier.
        offer_id: u64,
    },
}

/// Convenience result alias for `continuity-core`.
pub type CoreResult<T> = Result<T, CoreError>;
