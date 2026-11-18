import Foundation
import MirrorRenderer

/// Server settings for the native mirror window. The scrcpy client is not involved: we start
/// `scrcpy-server` ourselves, so options use the server's `key=value` names, not client flags.
public struct NativeMirrorConfig: Equatable, Sendable {
    public var mode: MirrorMode
    public var serverPath: String

    /// H.265 at 16 Mbit/s. scrcpy's default is H.264 at 8 Mbit/s, which stuttered in the
    /// Phase 1 hand test. M1 and later decode H.265 in hardware.
    public static let videoBitRate = 16_000_000
    public static let maxFps = 60

    /// Phone screen timeout during a panel-off session, in milliseconds (the server option
    /// takes ms; the scrcpy client flag takes seconds). The server restores the old value on exit.
    public static let panelOffScreenTimeoutMs = 3_600_000

    public init(mode: MirrorMode, serverPath: String) {
        self.mode = mode
        self.serverPath = serverPath
    }

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
            args += ["new_display=\(width)x\(height)/\(dpi)", "vd_destroy_content=false"]
        case .panelOff:
            args += ["stay_awake=true", "screen_off_timeout=\(Self.panelOffScreenTimeoutMs)"]
        }
        return args
    }

    /// Whether to turn the phone's panel off once video starts (scrcpy's `--turn-screen-off`
    /// is a control message, not a server option).
    public var turnsPanelOff: Bool { mode == .panelOff }

    public var streamOptions: ScrcpyStreamClient.ServerOptions {
        .init(serverPath: serverPath, videoBitRate: Self.videoBitRate, extraArguments: serverArguments)
    }
}
