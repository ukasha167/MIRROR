import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Big-endian binary encoder for the scrcpy v4 control socket protocol.
public enum ScrcpyControlEncoder {
    public enum MessageType: UInt8, Sendable {
        case injectKeycode = 0
        case injectText = 1
        case injectTouchEvent = 2
        case injectScrollEvent = 3
        case backOrScreenOn = 4
        case expandNotificationPanel = 5
        case expandSettingsPanel = 6
        case collapsePanels = 7
        case setClipboard = 9
        case setDisplayPower = 10
        case rotateDevice = 11
        case startApp = 16
        case resetVideo = 17
    }

    public enum TouchAction: UInt8, Sendable {
        case down = 0
        case up = 1
        case move = 2
    }

    public enum KeyAction: UInt8, Sendable {
        case down = 0
        case up = 1
    }

    /// Standard mouse pointer sentinel in scrcpy (`-1` as signed 64-bit / `0xffffffffffffffff`).
    public static let mousePointerId: UInt64 = UInt64(bitPattern: -1)
    public static let primaryButtonMask: UInt32 = 1 << 0
    public static let injectTextMaxBytes = 300

    /// Encodes a `TYPE_INJECT_TOUCH_EVENT` (32 bytes).
    /// Wire layout (big-endian):
    /// `[0] type=2 (u8), [1] action (u8), [2..10] pointerId (u64),`
    /// `[10..14] x (i32), [14..18] y (i32), [18..20] screenW (u16), [20..22] screenH (u16),`
    /// `[22..24] pressure (u16 0.16 fixed), [24..28] actionButton (u32), [28..32] buttons (u32)`.
    public static func injectTouch(
        action: TouchAction,
        pointerId: UInt64 = mousePointerId,
        x: Int32,
        y: Int32,
        screenWidth: UInt16,
        screenHeight: UInt16,
        pressure: Float,
        actionButton: UInt32 = primaryButtonMask,
        buttons: UInt32 = primaryButtonMask
    ) -> Data {
        var data = Data()
        data.reserveCapacity(32)
        data.append(MessageType.injectTouchEvent.rawValue)
        data.append(action.rawValue)
        appendBigEndian(pointerId, to: &data)
        appendPosition(x: x, y: y, width: screenWidth, height: screenHeight, to: &data)
        appendBigEndian(encodeU16Fixed(pressure), to: &data)
        appendBigEndian(actionButton, to: &data)
        appendBigEndian(buttons, to: &data)
        return data
    }

    /// Encodes a `TYPE_INJECT_SCROLL_EVENT` (21 bytes).
    /// Wire layout (big-endian):
    /// `[0] type=3 (u8), [1..13] Position (12B), [13..15] hScroll (i16 signed 16x),`
    /// `[15..17] vScroll (i16 signed 16x), [17..21] buttons (u32)`.
    public static func injectScroll(
        x: Int32,
        y: Int32,
        screenWidth: UInt16,
        screenHeight: UInt16,
        horizontalScroll: Float,
        verticalScroll: Float,
        buttons: UInt32 = 0
    ) -> Data {
        var data = Data()
        data.reserveCapacity(21)
        data.append(MessageType.injectScrollEvent.rawValue)
        appendPosition(x: x, y: y, width: screenWidth, height: screenHeight, to: &data)
        appendBigEndian(encodeScrollFixed(horizontalScroll), to: &data)
        appendBigEndian(encodeScrollFixed(verticalScroll), to: &data)
        appendBigEndian(buttons, to: &data)
        return data
    }

    /// Encodes `TYPE_INJECT_KEYCODE` (14 bytes).
    /// Wire layout (big-endian):
    /// `[0] type=0 (u8), [1] action (u8), [2..6] keycode (i32), [6..10] repeat (i32), [10..14] metaState (i32)`.
    public static func injectKeycode(
        action: KeyAction,
        keycode: Int32,
        repeatCount: Int32 = 0,
        metaState: Int32 = 0
    ) -> Data {
        var data = Data()
        data.reserveCapacity(14)
        data.append(MessageType.injectKeycode.rawValue)
        data.append(action.rawValue)
        appendBigEndian(keycode, to: &data)
        appendBigEndian(repeatCount, to: &data)
        appendBigEndian(metaState, to: &data)
        return data
    }

    /// Encodes `TYPE_INJECT_TEXT` (`1 + 4 + utf8.count` bytes, clamped cleanly to <= 300 UTF-8 bytes).
    /// Wire layout: `[0] type=1 (u8), [1..5] length (u32 BE), [5..] UTF-8`.
    public static func injectText(_ text: String) -> Data {
        let clamped = clampUTF8(text, maxBytes: injectTextMaxBytes)
        let utf8 = Data(clamped.utf8)
        var data = Data()
        data.reserveCapacity(5 + utf8.count)
        data.append(MessageType.injectText.rawValue)
        appendBigEndian(UInt32(utf8.count), to: &data)
        data.append(utf8)
        return data
    }

    /// Encodes `TYPE_BACK_OR_SCREEN_ON` (2 bytes: `[0]=4`, `[1]=action`).
    public static func backOrScreenOn(action: KeyAction) -> Data {
        Data([MessageType.backOrScreenOn.rawValue, action.rawValue])
    }

    /// Encodes both down and up `TYPE_BACK_OR_SCREEN_ON` events back-to-back.
    public static func backOrScreenOnTap() -> Data {
        backOrScreenOn(action: .down) + backOrScreenOn(action: .up)
    }

    /// Encodes a single-key tap (`down` followed by `up`) using `TYPE_INJECT_KEYCODE`.
    public static func tapKeycode(_ keycode: Int32, metaState: Int32 = 0) -> Data {
        injectKeycode(action: .down, keycode: keycode, repeatCount: 0, metaState: metaState)
            + injectKeycode(action: .up, keycode: keycode, repeatCount: 0, metaState: metaState)
    }

    /// Encodes `TYPE_SET_DISPLAY_POWER` (2 bytes: `[0]=10`, `[1]=on?1:0`).
    public static func setDisplayPower(on: Bool) -> Data {
        Data([MessageType.setDisplayPower.rawValue, on ? 1 : 0])
    }

    /// Encodes `TYPE_ROTATE_DEVICE` (1 byte: `[0]=11`).
    public static func rotateDevice() -> Data {
        Data([MessageType.rotateDevice.rawValue])
    }

    /// Encodes `TYPE_EXPAND_NOTIFICATION_PANEL` (1 byte: `[0]=5`).
    public static func expandNotificationPanel() -> Data {
        Data([MessageType.expandNotificationPanel.rawValue])
    }

    /// Encodes `TYPE_COLLAPSE_PANELS` (1 byte: `[0]=7`).
    public static func collapsePanels() -> Data {
        Data([MessageType.collapsePanels.rawValue])
    }

    /// Encodes `TYPE_RESET_VIDEO` (1 byte: `[0]=17`).
    public static func resetVideo() -> Data {
        Data([MessageType.resetVideo.rawValue])
    }

    /// Encodes `TYPE_SET_CLIPBOARD` (`[0]=9`, `[1..9] sequence (u64 BE)`, `[9] paste (u8)`, `[10..14] len (u32 BE)`, `[14..] UTF-8`).
    public static func setClipboard(_ text: String, sequence: UInt64 = 0, paste: Bool = true) -> Data {
        let clamped = clampUTF8(text, maxBytes: 262_100)
        let utf8 = Data(clamped.utf8)
        var data = Data()
        data.reserveCapacity(14 + utf8.count)
        data.append(MessageType.setClipboard.rawValue)
        appendBigEndian(sequence, to: &data)
        data.append(paste ? 1 : 0)
        appendBigEndian(UInt32(utf8.count), to: &data)
        data.append(utf8)
        return data
    }

    /// Encodes `TYPE_START_APP` (`[0]=16`, `[1] len (u8)`, `[2..] UTF-8 package name`, 1-byte length prefix per scrcpy 4.1).
    public static func startApp(packageName: String) -> Data {
        let clamped = clampUTF8(packageName, maxBytes: 255)
        let utf8 = Data(clamped.utf8)
        var data = Data()
        data.reserveCapacity(2 + utf8.count)
        data.append(MessageType.startApp.rawValue)
        data.append(UInt8(truncatingIfNeeded: utf8.count))
        data.append(utf8)
        return data
    }

    /// Android KeyEvent keycodes frequently emitted by macOS hardware keyboard translation.
    public enum AndroidKeyCode: Int32, Sendable {
        case home = 3
        case back = 4
        case dpadUp = 19
        case dpadDown = 20
        case dpadLeft = 21
        case dpadRight = 22
        case volumeUp = 24
        case volumeDown = 25
        case power = 26
        case tab = 61
        case space = 62
        case enter = 66
        case del = 67
        case pageUp = 92
        case pageDown = 93
        case escape = 111
        case forwardDel = 112
        case moveHome = 122
        case moveEnd = 123
        case appSwitch = 187
    }

    /// Maps a macOS virtual keyCode (`NSEvent.keyCode`) + character to an Android `KeyEvent.KEYCODE_*`.
    public static func androidKeyCode(macKeyCode: UInt16, charactersIgnoringModifiers: String?) -> Int32? {
        if let mapped = virtualKeyMap[macKeyCode] {
            return mapped
        }
        guard let scalar = charactersIgnoringModifiers?.lowercased().unicodeScalars.first?.value else {
            return nil
        }
        switch scalar {
        case 97...122: // 'a'...'z' -> KEYCODE_A (29)...KEYCODE_Z (54)
            return Int32(29 + (scalar - 97))
        case 48...57: // '0'...'9' -> KEYCODE_0 (7)...KEYCODE_9 (16)
            return Int32(7 + (scalar - 48))
        default:
            return asciiSymbolMap[scalar]
        }
    }

    #if canImport(AppKit)
    /// Converts `NSEvent.ModifierFlags` to Android `KeyEvent.META_*` flags.
    public static func androidMetaState(from flags: NSEvent.ModifierFlags) -> Int32 {
        var meta: Int32 = 0
        if flags.contains(.shift) { meta |= 0x1 }
        if flags.contains(.option) { meta |= 0x2 }
        if flags.contains(.control) { meta |= 0x1000 }
        if flags.contains(.command) { meta |= 0x10000 }
        return meta
    }
    #endif

    // MARK: - Private Binary Helpers

    private static func appendPosition(x: Int32, y: Int32, width: UInt16, height: UInt16, to data: inout Data) {
        appendBigEndian(x, to: &data)
        appendBigEndian(y, to: &data)
        appendBigEndian(width, to: &data)
        appendBigEndian(height, to: &data)
    }

    private static func appendBigEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var be = value.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }

    private static func encodeU16Fixed(_ value: Float) -> UInt16 {
        let clamped = max(0.0, min(1.0, value))
        if clamped >= 1.0 { return 0xffff }
        return UInt16(clamping: Int((clamped * 65536.0).rounded()))
    }

    private static func encodeScrollFixed(_ delta: Float) -> Int16 {
        let normalized = max(-1.0, min(1.0, delta / 16.0))
        if normalized >= 1.0 { return 0x7fff }
        if normalized <= -1.0 { return Int16.min }
        return Int16(clamping: Int((normalized * 32768.0).rounded()))
    }

    private static func clampUTF8(_ value: String, maxBytes: Int) -> String {
        var byteCount = 0
        var endIndex = value.startIndex
        for ch in value {
            let size = ch.utf8.count
            if byteCount + size > maxBytes { break }
            byteCount += size
            endIndex = value.index(after: endIndex)
        }
        return String(value[..<endIndex])
    }

    private static let virtualKeyMap: [UInt16: Int32] = [
        36: AndroidKeyCode.enter.rawValue,
        76: AndroidKeyCode.enter.rawValue,
        48: AndroidKeyCode.tab.rawValue,
        49: AndroidKeyCode.space.rawValue,
        51: AndroidKeyCode.del.rawValue,
        53: AndroidKeyCode.escape.rawValue,
        115: AndroidKeyCode.moveHome.rawValue,
        116: AndroidKeyCode.pageUp.rawValue,
        117: AndroidKeyCode.forwardDel.rawValue,
        119: AndroidKeyCode.moveEnd.rawValue,
        121: AndroidKeyCode.pageDown.rawValue,
        123: AndroidKeyCode.dpadLeft.rawValue,
        124: AndroidKeyCode.dpadRight.rawValue,
        125: AndroidKeyCode.dpadDown.rawValue,
        126: AndroidKeyCode.dpadUp.rawValue
    ]

    private static let asciiSymbolMap: [UInt32: Int32] = [
        44: 55, // ','
        46: 56, // '.'
        96: 68, // '`'
        45: 69, // '-'
        61: 70, // '='
        91: 71, // '['
        93: 72, // ']'
        92: 73, // '\'
        59: 74, // ';'
        39: 75, // '''
        47: 76  // '/'
    ]
}
