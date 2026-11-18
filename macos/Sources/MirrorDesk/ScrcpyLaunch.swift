import Foundation
import CoreGraphics

/// How the phone appears on the Mac.
public enum MirrorMode: Equatable, Sendable {
    /// A second Android screen that stays awake while the phone is locked (needs the desk-mode
    /// server patch). Apps open in tablet layout.
    case desk(width: Int, height: Int, dpi: Int)
    /// The phone's own screen, with the phone's panel turned off. The phone must stay unlocked.
    case panelOff

    public static let defaultDesk = MirrorMode.desk(width: 1600, height: 1000, dpi: deskDpi)

    /// Desk mode draws 1.5 phone pixels per Mac point at 240 dpi, so one Android dp is one
    /// Mac point: text on the virtual display is the size of Mac text.
    public static let deskDpi = 240
    public static let deskPixelsPerPoint: CGFloat = 1.5
    /// Longest virtual display side. Larger sizes cost encoder time for little sharpness.
    public static let deskMaxSide = 2560

    /// Virtual display size for a video area of `points`, in even pixel counts (the encoder
    /// wants even sizes).
    public static func deskPixels(forPoints points: CGSize) -> (width: Int, height: Int) {
        var w = points.width * deskPixelsPerPoint
        var h = points.height * deskPixelsPerPoint
        let longest = max(w, h)
        if longest > CGFloat(deskMaxSide) {
            w *= CGFloat(deskMaxSide) / longest
            h *= CGFloat(deskMaxSide) / longest
        }
        func even(_ v: CGFloat) -> Int { max(320, Int(v) & ~1) }
        return (even(w), even(h))
    }
}

/// Our patched scrcpy-server and the version it was built for.
public struct ScrcpyServer: Equatable, Sendable {
    public var path: String
    public var version: String

    /// Looks for `scrcpy-server-v<version>` where the build script and app bundle put it.
    /// The version must equal the client's (`scrcpy --version`), or the client rejects the server.
    public static func locate(
        clientVersion: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleResources: String? = Bundle.main.resourcePath,
        repoRoot: String = ScrcpyServer.repoRoot
    ) -> ScrcpyServer? {
        let name = "scrcpy-server-v\(clientVersion)"
        var candidates: [String] = []
        if let override = environment["MIRROR_SCRCPY_SERVER"] { candidates.append(override) }
        if let res = bundleResources { candidates.append("\(res)/\(name)") }
        candidates.append("\(NSHomeDirectory())/Library/Application Support/Mirror/\(name)")
        candidates.append("\(repoRoot)/build/\(name)")
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            return ScrcpyServer(path: path, version: clientVersion)
        }
        return nil
    }

    /// Repository root, found from this source file's location. Lets `swift run` use
    /// `build/` without installing anything.
    public static let repoRoot: String = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() } // MirrorDesk, Sources, macos
        return url.path
    }()

    /// Reads the version from `scrcpy --version` ("scrcpy 4.1 <https://...>").
    public static func parseClientVersion(_ output: String) -> String? {
        let fields = output.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 2, fields[0] == "scrcpy" else { return nil }
        return String(fields[1])
    }
}
