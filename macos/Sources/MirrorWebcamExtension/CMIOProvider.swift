import Foundation
import CoreMedia
import CoreMediaIO

/// CoreMediaIO extension virtual camera device properties.
public struct VirtualCameraDeviceConfig: Sendable {
    public let localizedName: String
    public let deviceID: UUID
    public let manufacturer: String
    public let modelID: String

    public init(
        localizedName: String = "Android Continuity Camera",
        deviceID: UUID = UUID(uuidString: "8B4F9A6C-27D4-4E3F-912A-18F63B4C5D9E")!,
        manufacturer: String = "Mirror Continuity",
        modelID: String = "Mirror-Continuity-Cam"
    ) {
        self.localizedName = localizedName
        self.deviceID = deviceID
        self.manufacturer = manufacturer
        self.modelID = modelID
    }
}

/// Provider managing the virtual camera device and sink/source streams.
public final class VirtualCameraProvider: @unchecked Sendable {
    public let config: VirtualCameraDeviceConfig
    public let demandManager: CameraDemandManager

    public init(config: VirtualCameraDeviceConfig = VirtualCameraDeviceConfig()) {
        self.config = config
        self.demandManager = CameraDemandManager()
    }

    /// Generates scrcpy camera command arguments to start camera streaming on phone.
    public func scrcpyCameraArguments(
        format: CameraStreamFormat = .fullHD60,
        facing: String = "back"
    ) -> [String] {
        [
            "--video-source=camera",
            "--camera-size=\(format.width)x\(format.height)",
            "--camera-fps=\(Int(format.maxFps))",
            "--camera-facing=\(facing)",
            "--audio-source=mic-voice-communication"
        ]
    }
}
