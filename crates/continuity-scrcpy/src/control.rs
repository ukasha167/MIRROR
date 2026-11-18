//! Binary control message serializer (`Mac client -> scrcpy-server` control socket).
//! All multi-byte fields in `scrcpy` v3.x-v5.0 control packets use **big-endian** byte order.

use crate::error::{Result, ScrcpyError};

/// Control message type IDs (`scrcpy` v3.x-v5.0 wire format).
pub const TYPE_INJECT_KEYCODE: u8 = 0;
/// Inject UTF-8 text string (`u32` length prefix).
pub const TYPE_INJECT_TEXT: u8 = 1;
/// Inject touch pointer event with fixed-point pressure and 64-bit pointer ID.
pub const TYPE_INJECT_TOUCH_EVENT: u8 = 2;
/// Inject trackpad/mouse wheel scroll event (`i16` fixed-point horizontal/vertical scroll).
pub const TYPE_INJECT_SCROLL_EVENT: u8 = 3;
/// Press Back button or turn screen on if currently off.
pub const TYPE_BACK_OR_SCREEN_ON: u8 = 4;
/// Expand Android notification shade.
pub const TYPE_EXPAND_NOTIFICATION_PANEL: u8 = 5;
/// Expand Android Quick Settings panel.
pub const TYPE_EXPAND_SETTINGS_PANEL: u8 = 6;
/// Collapse status bar / notification / settings panels.
pub const TYPE_COLLAPSE_PANELS: u8 = 7;
/// Request current Android clipboard text (`CopyKey` mode).
pub const TYPE_GET_CLIPBOARD: u8 = 8;
/// Set Android clipboard text with sequence number and optional immediate paste.
pub const TYPE_SET_CLIPBOARD: u8 = 9;
/// Toggle physical phone display power (`SurfaceControl.setDisplayPowerMode` / OLED off).
pub const TYPE_SET_DISPLAY_POWER: u8 = 10;
/// Create a Linux kernel `/dev/uhid` virtual HID mouse or keyboard device.
pub const TYPE_UHID_CREATE: u8 = 12;
/// Send a raw HID report to an active `/dev/uhid` virtual device.
pub const TYPE_UHID_INPUT: u8 = 13;
/// Destroy a previously registered `/dev/uhid` virtual device.
pub const TYPE_UHID_DESTROY: u8 = 14;
/// Start an Android app by package name (or `+package` to force-stop before launch).
pub const TYPE_START_APP: u8 = 16;
/// Reset the video encoder stream to recover from decoder stalls or request a fresh IDR frame.
pub const TYPE_RESET_VIDEO: u8 = 17;
/// Maximum UTF-8 payload size for `InjectText` (`300` bytes).
pub const MAX_INJECT_TEXT_BYTES: usize = 300;
/// Maximum UTF-8 payload size for `SetClipboard` (`256 KiB` minus header).
pub const MAX_CLIPBOARD_TEXT_BYTES: usize = (1 << 18) - 14;
/// Special `pointer_id` constant representing a virtual mouse cursor (`-1i64` as `u64`).
pub const POINTER_ID_MOUSE: u64 = u64::MAX;
/// Special `pointer_id` constant representing a generic finger touch (`-2i64` as `u64`).
pub const POINTER_ID_GENERIC_FINGER: u64 = u64::MAX - 1;

/// Android `KeyEvent` action byte (`ACTION_DOWN = 0`, `ACTION_UP = 1`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum KeyEventAction {
    /// Key pressed (`AKEY_EVENT_ACTION_DOWN`).
    Down = 0,
    /// Key released (`AKEY_EVENT_ACTION_UP`).
    Up = 1,
}

/// Android `MotionEvent` action byte for touch and mouse injection.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum MotionEventAction {
    /// Primary pointer pressed.
    Down = 0,
    /// Primary pointer released.
    Up = 1,
    /// Pointer moved.
    Move = 2,
    /// Gesture cancelled.
    Cancel = 3,
    /// Cursor hovering without buttons pressed.
    HoverMove = 7,
    /// Mouse cursor entered window.
    HoverEnter = 9,
    /// Mouse cursor exited window.
    HoverExit = 10,
}

/// Copy key behavior when requesting the Android clipboard via `GetClipboard`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum CopyKey {
    /// Read clipboard without injecting a synthetic key event.
    None = 0,
    /// Inject `Ctrl+C` (`KEYCODE_COPY`) before reading clipboard.
    Copy = 1,
    /// Inject `Ctrl+X` (`KEYCODE_CUT`) before reading clipboard.
    Cut = 2,
}

/// Screen geometry and pixel coordinates used in touch and scroll events (`12` bytes).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ScreenPosition {
    /// Horizontal coordinate in pixels.
    pub x: i32,
    /// Vertical coordinate in pixels.
    pub y: i32,
    /// Target video frame width in pixels.
    pub screen_width: u16,
    /// Target video frame height in pixels.
    pub screen_height: u16,
}

impl ScreenPosition {
    /// Appends the 12-byte big-endian position structure (`i32 x`, `i32 y`, `u16 width`, `u16 height`).
    pub fn write_to(self, out: &mut Vec<u8>) {
        out.extend_from_slice(&self.x.to_be_bytes());
        out.extend_from_slice(&self.y.to_be_bytes());
        out.extend_from_slice(&self.screen_width.to_be_bytes());
        out.extend_from_slice(&self.screen_height.to_be_bytes());
    }
}

fn encode_pressure_u16(pressure: f32) -> Result<u16> {
    if !pressure.is_finite() || !(0.0..=1.0).contains(&pressure) {
        return Err(ScrcpyError::InvalidTouchPressure { pressure_bits: pressure.to_bits() });
    }
    Ok((pressure * 65535.0).round() as u16)
}

/// Strongly typed `scrcpy` v3.x-v5.0 client-to-server control messages.
#[derive(Debug, Clone, PartialEq)]
pub enum ControlMessage {
    /// Inject an Android hardware/virtual keycode (`14B`: `[u8 type=0, u8 action, u32 keycode, u32 repeat, u32 meta]`).
    InjectKeycode {
        /// Key press or release action.
        action: KeyEventAction,
        /// Android `AKEYCODE_*` constant.
        keycode: u32,
        /// Key repeat counter.
        repeat: u32,
        /// Android `AMETA_*` modifier bitmask.
        metastate: u32,
    },
    /// Inject UTF-8 text directly into the focused input field (`5+NB`: `[u8 type=1, u32 len, utf8...]`).
    InjectText {
        /// Text string to type (max `300` UTF-8 bytes).
        text: String,
    },
    /// Inject a touch or mouse pointer event (`32B`: `[u8 type=2, u8 action, u64 ptr_id, 12B pos, u16 press, u32 act_btn, u32 btns]`).
    InjectTouchEvent {
        /// Motion action (`Down`, `Up`, `Move`, `HoverMove`, etc.).
        action: MotionEventAction,
        /// Unique pointer identifier (`POINTER_ID_MOUSE`, `POINTER_ID_GENERIC_FINGER`, or finger index).
        pointer_id: u64,
        /// Touch coordinates and active frame dimensions.
        position: ScreenPosition,
        /// Normalized pressure in `0.0..=1.0` (encoded as `u16` fixed point `0x0000..=0xFFFF`).
        pressure: f32,
        /// Button state bitmask that changed in this event.
        action_button: u32,
        /// Currently pressed button state bitmask.
        buttons: u32,
    },
    /// Inject a scroll wheel / two-finger trackpad scroll event (`21B`: `[u8 type=3, 12B pos, i16 h, i16 v, u32 btns]`).
    InjectScrollEvent {
        /// Cursor coordinates and active frame dimensions.
        position: ScreenPosition,
        /// Horizontal scroll delta in signed 16-bit fixed point.
        hscroll: i16,
        /// Vertical scroll delta in signed 16-bit fixed point.
        vscroll: i16,
        /// Currently pressed mouse buttons bitmask.
        buttons: u32,
    },
    /// Press the Back key or wake the screen if off (`2B`: `[u8 type=4, u8 action]`).
    BackOrScreenOn {
        /// Key action (`Down` then `Up`).
        action: KeyEventAction,
    },
    /// Expand the Android notification shade (`1B`: `[u8 type=5]`).
    ExpandNotificationPanel,
    /// Expand the Android Quick Settings panel (`1B`: `[u8 type=6]`).
    ExpandSettingsPanel,
    /// Collapse all status bar panels (`1B`: `[u8 type=7]`).
    CollapsePanels,
    /// Request the current Android clipboard (`2B`: `[u8 type=8, u8 copy_key]`).
    GetClipboard {
        /// Whether to synthesize Copy/Cut before reading.
        copy_key: CopyKey,
    },
    /// Set the Android clipboard (`14+NB`: `[u8 type=9, u64 seq, u8 paste, u32 len, utf8...]`).
    SetClipboard {
        /// Monotonic clipboard sequence number echoed back by the server.
        sequence: u64,
        /// Whether `scrcpy-server` should immediately inject `Ctrl+V` after setting.
        paste: bool,
        /// UTF-8 clipboard text payload.
        text: String,
    },
    /// Turn physical OLED panel on or off while keeping mirroring active (`2B`: `[u8 type=10, u8 on]`).
    SetDisplayPower {
        /// `false` turns the physical phone screen off (0 mW OLED draw); `true` turns it back on.
        on: bool,
    },
    /// Register a Linux kernel `/dev/uhid` virtual HID peripheral (`10+M+NB`).
    UhidCreate {
        /// Client-chosen device slot ID.
        id: u16,
        /// USB Vendor ID.
        vendor_id: u16,
        /// USB Product ID.
        product_id: u16,
        /// Human-readable device name (`<= 127` bytes).
        name: String,
        /// Raw USB HID report descriptor bytes.
        report_desc: Vec<u8>,
    },
    /// Send a raw HID input report to an existing `/dev/uhid` device (`5+NB`: `[u8 type=13, u16 id, u16 len, data...]`).
    UhidInput {
        /// Device slot ID registered via [`ControlMessage::UhidCreate`].
        id: u16,
        /// Raw HID report bytes.
        data: Vec<u8>,
    },
    /// Destroy a registered `/dev/uhid` virtual device (`3B`: `[u8 type=14, u16 id]`).
    UhidDestroy {
        /// Device slot ID to close.
        id: u16,
    },
    /// Launch an Android application by package name (`2+NB`: `[u8 type=16, u8 len, pkg...]`).
    StartApp {
        /// Package name (prefix with `+` to force-stop the package before starting).
        package_name: String,
    },
    /// Reset the server video encoder and request a fresh keyframe (`1B`: `[u8 type=17]`).
    ResetVideo,
}

impl ControlMessage {
    /// Serializes this control message into `out` following the big-endian `scrcpy` v3.x-v5.0 binary layout.
    pub fn serialize_into(&self, out: &mut Vec<u8>) -> Result<()> {
        match self {
            Self::InjectKeycode { action, keycode, repeat, metastate } => {
                out.reserve(14);
                out.extend_from_slice(&[TYPE_INJECT_KEYCODE, *action as u8]);
                out.extend_from_slice(&keycode.to_be_bytes());
                out.extend_from_slice(&repeat.to_be_bytes());
                out.extend_from_slice(&metastate.to_be_bytes());
            }
            Self::InjectText { text } => {
                let bytes = text.as_bytes();
                if bytes.len() > MAX_INJECT_TEXT_BYTES {
                    return Err(ScrcpyError::ControlPayloadTooLarge {
                        message_type: "InjectText", max_len: MAX_INJECT_TEXT_BYTES, actual_len: bytes.len(),
                    });
                }
                out.reserve(5 + bytes.len());
                out.push(TYPE_INJECT_TEXT);
                out.extend_from_slice(&(bytes.len() as u32).to_be_bytes());
                out.extend_from_slice(bytes);
            }
            Self::InjectTouchEvent { action, pointer_id, position, pressure, action_button, buttons } => {
                let pressure_u16 = encode_pressure_u16(*pressure)?;
                out.reserve(32);
                out.extend_from_slice(&[TYPE_INJECT_TOUCH_EVENT, *action as u8]);
                out.extend_from_slice(&pointer_id.to_be_bytes());
                position.write_to(out);
                out.extend_from_slice(&pressure_u16.to_be_bytes());
                out.extend_from_slice(&action_button.to_be_bytes());
                out.extend_from_slice(&buttons.to_be_bytes());
            }
            Self::InjectScrollEvent { position, hscroll, vscroll, buttons } => {
                out.reserve(21);
                out.push(TYPE_INJECT_SCROLL_EVENT);
                position.write_to(out);
                out.extend_from_slice(&hscroll.to_be_bytes());
                out.extend_from_slice(&vscroll.to_be_bytes());
                out.extend_from_slice(&buttons.to_be_bytes());
            }
            Self::BackOrScreenOn { action } => out.extend_from_slice(&[TYPE_BACK_OR_SCREEN_ON, *action as u8]),
            Self::ExpandNotificationPanel => out.push(TYPE_EXPAND_NOTIFICATION_PANEL),
            Self::ExpandSettingsPanel => out.push(TYPE_EXPAND_SETTINGS_PANEL),
            Self::CollapsePanels => out.push(TYPE_COLLAPSE_PANELS),
            Self::GetClipboard { copy_key } => out.extend_from_slice(&[TYPE_GET_CLIPBOARD, *copy_key as u8]),
            Self::SetClipboard { sequence, paste, text } => {
                let bytes = text.as_bytes();
                if bytes.len() > MAX_CLIPBOARD_TEXT_BYTES {
                    return Err(ScrcpyError::ControlPayloadTooLarge {
                        message_type: "SetClipboard", max_len: MAX_CLIPBOARD_TEXT_BYTES, actual_len: bytes.len(),
                    });
                }
                out.reserve(14 + bytes.len());
                out.push(TYPE_SET_CLIPBOARD);
                out.extend_from_slice(&sequence.to_be_bytes());
                out.push(u8::from(*paste));
                out.extend_from_slice(&(bytes.len() as u32).to_be_bytes());
                out.extend_from_slice(bytes);
            }
            Self::SetDisplayPower { on } => out.extend_from_slice(&[TYPE_SET_DISPLAY_POWER, u8::from(*on)]),
            Self::UhidCreate { id, vendor_id, product_id, name, report_desc } => {
                let name_bytes = name.as_bytes();
                if name_bytes.len() > 127 {
                    return Err(ScrcpyError::ControlPayloadTooLarge {
                        message_type: "UhidCreate.name", max_len: 127, actual_len: name_bytes.len(),
                    });
                }
                if report_desc.is_empty() || report_desc.len() > u16::MAX as usize {
                    return Err(ScrcpyError::ControlPayloadTooLarge {
                        message_type: "UhidCreate.report_desc", max_len: u16::MAX as usize, actual_len: report_desc.len(),
                    });
                }
                out.reserve(10 + name_bytes.len() + report_desc.len());
                out.push(TYPE_UHID_CREATE);
                out.extend_from_slice(&id.to_be_bytes());
                out.extend_from_slice(&vendor_id.to_be_bytes());
                out.extend_from_slice(&product_id.to_be_bytes());
                out.push(name_bytes.len() as u8);
                out.extend_from_slice(name_bytes);
                out.extend_from_slice(&(report_desc.len() as u16).to_be_bytes());
                out.extend_from_slice(report_desc);
            }
            Self::UhidInput { id, data } => {
                if data.is_empty() || data.len() > u16::MAX as usize {
                    return Err(ScrcpyError::ControlPayloadTooLarge {
                        message_type: "UhidInput.data", max_len: u16::MAX as usize, actual_len: data.len(),
                    });
                }
                out.reserve(5 + data.len());
                out.push(TYPE_UHID_INPUT);
                out.extend_from_slice(&id.to_be_bytes());
                out.extend_from_slice(&(data.len() as u16).to_be_bytes());
                out.extend_from_slice(data);
            }
            Self::UhidDestroy { id } => {
                out.push(TYPE_UHID_DESTROY);
                out.extend_from_slice(&id.to_be_bytes());
            }
            Self::StartApp { package_name } => {
                let bytes = package_name.as_bytes();
                if bytes.is_empty() || bytes.len() > u8::MAX as usize {
                    return Err(ScrcpyError::ControlPayloadTooLarge {
                        message_type: "StartApp.package_name", max_len: u8::MAX as usize, actual_len: bytes.len(),
                    });
                }
                out.reserve(2 + bytes.len());
                out.extend_from_slice(&[TYPE_START_APP, bytes.len() as u8]);
                out.extend_from_slice(bytes);
            }
            Self::ResetVideo => out.push(TYPE_RESET_VIDEO),
        }
        Ok(())
    }

    /// Convenience helper returning the serialized control packet as a newly allocated `Vec<u8>`.
    pub fn to_bytes(&self) -> Result<Vec<u8>> {
        let mut buf = Vec::with_capacity(32);
        self.serialize_into(&mut buf)?;
        Ok(buf)
    }
}
