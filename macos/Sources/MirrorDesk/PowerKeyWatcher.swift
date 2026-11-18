import Foundation

/// Watches the phone's power button during a panel-off session.
///
/// In that session the phone is awake with its panel dark. A power press puts it to sleep, so
/// the user saw nothing happen and had to press again (Phase 1 hand test). We see the press in
/// `getevent` (the shell user is in the `input` group), wake the phone and end the session, so
/// one press gives the user their phone back.
public final class PowerKeyWatcher: @unchecked Sendable {
    private let process = Process()
    private var buffer = ""
    private let lock = NSLock()

    /// Runs on a background queue once per power key press.
    public var onPress: (@Sendable () -> Void)?

    public init(adbPath: String, serial: String) {
        process.executableURL = URL(fileURLWithPath: adbPath)
        // -l: key names, -q: no device list header. All devices, since the power key's
        // device name differs per phone.
        process.arguments = ["-s", serial, "shell", "getevent", "-lq"]
    }

    public func start() throws {
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self, !chunk.isEmpty else { return }
            let presses = self.lock.withLock { () -> Int in
                self.buffer += String(decoding: chunk, as: UTF8.self)
                var lines = self.buffer.components(separatedBy: "\n")
                self.buffer = lines.removeLast()
                return lines.filter(Self.isPowerDown).count
            }
            for _ in 0..<presses { self.onPress?() }
        }
        process.terminationHandler = { _ in pipe.fileHandleForReading.readabilityHandler = nil }
        try process.run()
    }

    public func stop() {
        if process.isRunning { process.terminate() }
    }

    /// A `getevent -lq` line looks like
    /// `/dev/input/event2: EV_KEY       KEY_POWER            DOWN`.
    static func isPowerDown(_ line: String) -> Bool {
        let fields = line.split(whereSeparator: \.isWhitespace)
        return fields.count >= 4 && fields[1] == "EV_KEY" && fields[2] == "KEY_POWER" && fields[3] == "DOWN"
    }
}
