import Foundation
import MirrorRenderer

/// Server settings for the native mirror window. The scrcpy client is not involved: we start
/// `scrcpy-server` ourselves, so options use the server's `key=value` names, not client flags.
public struct NativeMirrorConfig: Equatable, Sendable {
    public var mode: MirrorMode
    public var serverPath: String
    public var transport: AdbDevice.Transport
    /// One phone app on its own display: no Android status bar or taskbar, no audio (the desk
    /// or phone window that opened it already plays the phone's sound).
    public var soloApp: Bool

    /// H.265 at 16 Mbit/s over USB. scrcpy's default is H.264 at 8 Mbit/s, which stuttered in
    /// the Phase 1 hand test. M1 and later decode H.265 in hardware.
    public static let usbVideoBitRate = 16_000_000
    /// Over Wi-Fi, 8 Mbit/s. adb over Wi-Fi measured 6 MB/s (48 Mbit/s) on the test network,
    /// and a file push shares that link with the video.
    public static let wifiVideoBitRate = 8_000_000
    public static let maxFps = 60

    /// Phone screen timeout during a panel-off session, in milliseconds (the server option
    /// takes ms; the scrcpy client flag takes seconds). The server restores the old value on exit.
    public static let panelOffScreenTimeoutMs = 3_600_000

    public init(mode: MirrorMode, serverPath: String, transport: AdbDevice.Transport = .usb, soloApp: Bool = false) {
        self.mode = mode
        self.serverPath = serverPath
        self.transport = transport
        self.soloApp = soloApp
    }

    /// Phone sound plays on the Mac and the phone's speaker goes quiet.
    public var audio: Bool { !soloApp }

    public var videoBitRate: Int { transport == .usb ? Self.usbVideoBitRate : Self.wifiVideoBitRate }

    /// Longest video side. 0 keeps the virtual display at its own size.
    public var maxSize: Int {
        switch mode {
        case .desk: 0
        case .panelOff: 1920
        }
    }

    public var serverArguments: [String] {
        // The clipboard bridge owns clipboard sync; a second listener would echo text back.
        var args = ["clipboard_autosync=false"]
        switch mode {
        case .desk(let width, let height, let dpi):
            // flex_display lets the window resize the virtual display (RESIZE_DISPLAY).
            // vd_destroy_content=false moves the display's apps to the phone's screen when the
            // session ends, so a reconnect can bring them back instead of killing them.
            args += ["new_display=\(width)x\(height)/\(dpi)", "flex_display=true", "vd_destroy_content=false",
                     // The keyboard opens on this display, not on the locked phone.
                     "display_ime_policy=local"]
            // Android's status bar and taskbar covered the bottom of a solo app (Instagram's tabs
            // in the hand test). The window's title bar has Back instead.
            if soloApp { args.append("vd_system_decorations=false") }
        case .panelOff:
            args += ["stay_awake=true", "screen_off_timeout=\(Self.panelOffScreenTimeoutMs)"]
        }
        return args
    }

    /// Whether to turn the phone's panel off once video starts (scrcpy's `--turn-screen-off`
    /// is a control message, not a server option).
    public var turnsPanelOff: Bool { mode == .panelOff }

    public var streamOptions: ScrcpyStreamClient.ServerOptions {
        .init(serverPath: serverPath, videoBitRate: videoBitRate, extraArguments: serverArguments, audio: audio)
    }
}
