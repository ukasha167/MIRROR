import Foundation
import Combine
import SwiftUI
import AppKit
import CoreGraphics
import MirrorCoreBridge
import MirrorRenderer
import MirrorWebcamExtension
import MirrorFSExtension
import NearDropReceiver

/// Central ViewModel driving continuity presence, dual-direction pairing, inline Metal scrcpy mirroring, and peripheral state.
@MainActor
public final class MirrorAppAgent: ObservableObject {
    @Published public var isConnected: Bool = false
    @Published public var deviceName: String = "No Device Connected"
    @Published public var batteryPercentage: Int = 100
    @Published public var isCharging: Bool = false
    @Published public var isMirroring: Bool = false
    @Published public var isWebcamActive: Bool = false
    @Published public var isFinderVolumeMounted: Bool = false
    @Published public var activeOTP: OTPEvent?

    // Presence & Pairing State
    @Published public var usbAttached: UsbAttachedDevice?
    @Published public var discoveredPeers: [DiscoveredContinuityPeer] = []
    @Published public var trustedPeers: [TrustedPeerRecord] = []
    @Published public var connectionTransportLabel: String = ""
    @Published public var pairingQrPayload: String = ""
    @Published public var pairingPin: String = ""
    @Published public var listeningPort: UInt16 = ContinuityHostServer.defaultListenPort
    @Published public var isPairingInProgress: Bool = false
    @Published public var pairingErrorMessage: String?

    // Inline Mirror Stage State
    @Published public var streamVideoSize: CGSize = .zero
    @Published public var phonePhysicalScreenSize: CGSize?
    @Published public var activeCodecLabel: String = "H.265"
    @Published public var mirrorErrorMessage: String?
    @Published public var isPhoneScreenDimmed: Bool = false
    @Published public var canMirrorViaAdb: Bool = false

    // Media & Transfer Feedback
    @Published public var mediaState: MediaPlaybackState = .empty
    @Published public var fileTransferMessage: String?

    public let bridge: any ContinuityBridgeProtocol
    public let displayController: VirtualDisplayController
    public let webcamProvider: VirtualCameraProvider
    public let fsManager: FSKitVolumeManager
    public let nearDropReceiver: ReceiverStateMachine
    public let frameSink = MirrorFrameSink()
    public let streamClient = ScrcpyStreamClient()

    private var pollTask: Task<Void, Never>?

    public var effectiveVideoDimensions: CGSize {
        if streamVideoSize.width > 0 && streamVideoSize.height > 0 {
            return streamVideoSize
        }
        if let physical = phonePhysicalScreenSize, physical.width > 0 && physical.height > 0 {
            return physical
        }
        return CGSize(width: 1080, height: 2400)
    }

    public init(
        bridge: any ContinuityBridgeProtocol = LiveContinuityBridge(),
        displayController: VirtualDisplayController = VirtualDisplayController(),
        webcamProvider: VirtualCameraProvider = VirtualCameraProvider(),
        fsManager: FSKitVolumeManager = FSKitVolumeManager(),
        nearDropReceiver: ReceiverStateMachine = ReceiverStateMachine()
    ) {
        self.bridge = bridge
        self.displayController = displayController
        self.webcamProvider = webcamProvider
        self.fsManager = fsManager
        self.nearDropReceiver = nearDropReceiver

        configureStreamCallbacks()
        configureHostServerCallbacks()

        if let live = bridge as? LiveContinuityBridge {
            let info = live.currentPairingInfo()
            self.pairingQrPayload = info.qrPayload
            self.pairingPin = info.pin
            self.listeningPort = live.hostServer.boundPort
        }

        Task { await refreshDeviceState() }

        self.pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                await self?.refreshDeviceState()
            }
        }
    }

    private func configureStreamCallbacks() {
        let sink = self.frameSink
        streamClient.onPixelBuffer = { pixelBuffer, _ in
            sink.submit(pixelBuffer: pixelBuffer)
        }
        streamClient.onVideoDimensionsChanged = { [weak self] size in
            Task { @MainActor [weak self] in
                guard let self, size.width > 0, size.height > 0 else { return }
                self.streamVideoSize = size
            }
        }
        streamClient.onDeviceName = { [weak self] _, codec in
            Task { @MainActor [weak self] in
                self?.activeCodecLabel = codec == .h265 ? "H.265" : "H.264"
            }
        }
        streamClient.onStateChanged = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .idle:
                    self.isMirroring = false
                    self.isPhoneScreenDimmed = false
                case .starting:
                    self.mirrorErrorMessage = nil
                case .streaming(let w, let h, let codec):
                    self.isMirroring = true
                    self.mirrorErrorMessage = nil
                    self.streamVideoSize = CGSize(width: w, height: h)
                    self.activeCodecLabel = codec == .h265 ? "H.265" : "H.264"
                case .failed(let msg):
                    self.isMirroring = false
                    self.mirrorErrorMessage = msg
                }
            }
        }
    }

    private func configureHostServerCallbacks() {
        guard let live = bridge as? LiveContinuityBridge else { return }
        live.hostServer.onConnectedPeerChanged = { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refreshDeviceState() }
        }
        live.hostServer.onDiscoveredPeersChanged = { [weak self] peers in
            Task { @MainActor [weak self] in self?.discoveredPeers = peers }
        }
        live.hostServer.onRemoteMediaChanged = { [weak self] title, artist, playing in
            Task { @MainActor [weak self] in
                if let title, !title.isEmpty {
                    self?.mediaState = MediaPlaybackState(trackTitle: title, artist: artist ?? "", isPlaying: playing)
                } else {
                    self?.mediaState = .empty
                }
            }
        }
        live.hostServer.onRemoteClipboardReceived = { text in
            Task { @MainActor in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
    }

    public func refreshDeviceState() async {
        if let live = bridge as? LiveContinuityBridge {
            let snapshot = await live.refreshConnectionState()
            usbAttached = snapshot.usbAttached
            discoveredPeers = snapshot.discoveredPeers
            trustedPeers = snapshot.trustedPeers
            phonePhysicalScreenSize = snapshot.usbAttached?.screenSize
            listeningPort = live.hostServer.boundPort
            let pairing = live.currentPairingInfo()
            pairingQrPayload = pairing.qrPayload
            pairingPin = pairing.pin

            if let dev = snapshot.activeDevice {
                isConnected = true
                deviceName = dev.name
                batteryPercentage = Int((dev.batteryLevel ?? 1.0) * 100)
                isCharging = dev.isCharging
                connectionTransportLabel = dev.transport == .usbAdb ? "USB" : "Wi-Fi"
                canMirrorViaAdb = await live.resolveAdbSerial() != nil
                pairingErrorMessage = nil
                return
            }

            isConnected = false
            deviceName = snapshot.usbAttached?.model ?? "No Device Connected"
            connectionTransportLabel = ""
            canMirrorViaAdb = false
            if isMirroring { stopMirroringInternal() }
            return
        }

        if let dev = await bridge.activeDevice {
            isConnected = true
            deviceName = dev.name
            batteryPercentage = Int((dev.batteryLevel ?? 1.0) * 100)
            isCharging = dev.isCharging
            connectionTransportLabel = "Connected"
            canMirrorViaAdb = true
        } else {
            isConnected = false
            deviceName = "No Device Connected"
            connectionTransportLabel = ""
            canMirrorViaAdb = false
            isMirroring = false
        }
    }

    public func refreshPairingCode() {
        guard let live = bridge as? LiveContinuityBridge else { return }
        let updated = live.rotatePairingInfo()
        pairingQrPayload = updated.qrPayload
        pairingPin = updated.pin
        pairingErrorMessage = nil
    }

    public func pairWithPhoneCode(peerId: String?, manualAddress: String?, pinCode: String) {
        guard let live = bridge as? LiveContinuityBridge else { return }
        isPairingInProgress = true
        pairingErrorMessage = nil
        Task {
            do {
                _ = try await live.pairWithPhone(peerId: peerId, manualAddress: manualAddress, pinCode: pinCode)
                isPairingInProgress = false
                await refreshDeviceState()
            } catch {
                isPairingInProgress = false
                pairingErrorMessage = error.localizedDescription
            }
        }
    }

    public func unpairCurrentDevice() {
        guard let live = bridge as? LiveContinuityBridge else { return }
        stopMirroringInternal()
        Task {
            await live.unpairDevice()
            await refreshDeviceState()
        }
    }

    public func toggleMirroring() {
        Task { await toggleScreenMirror() }
    }

    public func toggleScreenMirror() async {
        if isMirroring {
            stopMirroringInternal()
            try? await bridge.stopMirroring()
        } else {
            await startMirroring(appPackage: nil)
        }
    }

    public func launchApp(packageName: String) {
        Task {
            if isMirroring {
                streamClient.sendControl(ScrcpyControlEncoder.startApp(packageName: packageName))
            } else {
                await startMirroring(appPackage: packageName)
            }
        }
    }

    private func startMirroring(appPackage: String?) async {
        mirrorErrorMessage = nil
        if let live = bridge as? LiveContinuityBridge {
            guard let dev = await live.activeDevice else { return }
            guard let serial = await live.resolveAdbSerial() else {
                mirrorErrorMessage = "Connect USB cable or ADB Wi-Fi to mirror \(dev.name)."
                return
            }
            do {
                isMirroring = true
                try await streamClient.start(serial: serial, adbPath: live.adbPath, initialPackage: appPackage)
                try? await live.startMirroring(deviceId: dev.id, appPackage: appPackage)
            } catch {
                isMirroring = false
                mirrorErrorMessage = error.localizedDescription
            }
        } else if let dev = await bridge.activeDevice {
            try? await bridge.startMirroring(deviceId: dev.id, appPackage: appPackage)
            isMirroring = true
        }
    }

    private func stopMirroringInternal() {
        streamClient.stop()
        isMirroring = false
        isPhoneScreenDimmed = false
    }

    public func sendMirrorControl(_ data: Data) { streamClient.sendControl(data) }
    public func sendNavigationKey(_ key: ScrcpyControlEncoder.AndroidKeyCode) {
        streamClient.sendControl(ScrcpyControlEncoder.tapKeycode(key.rawValue))
    }
    public func sendRotateDevice() { streamClient.sendControl(ScrcpyControlEncoder.rotateDevice()) }
    public func togglePhoneDisplayPower() {
        isPhoneScreenDimmed.toggle()
        streamClient.sendControl(ScrcpyControlEncoder.setDisplayPower(on: !isPhoneScreenDimmed))
    }

    public func toggleWebcam() {
        if isWebcamActive {
            webcamProvider.demandManager.reset()
            isWebcamActive = false
        } else {
            webcamProvider.demandManager.clientDidConnect("LocalHost")
            isWebcamActive = true
        }
    }

    public func toggleFinderVolume() {
        if isFinderVolumeMounted {
            try? fsManager.unmount()
            isFinderVolumeMounted = false
        } else {
            try? fsManager.mount(volume: AndroidVolumeInfo(volumeName: "\(deviceName) Storage"))
            isFinderVolumeMounted = true
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: "/tmp")
        }
    }

    public func pushFile(url: URL) async -> Bool {
        fileTransferMessage = "Sending \(url.lastPathComponent)..."
        if let live = bridge as? LiveContinuityBridge {
            let ok = (try? await live.pushFile(localPath: url.path)) ?? false
            fileTransferMessage = ok ? "Sent \(url.lastPathComponent) to Downloads" : "Transfer requires an active USB/ADB connection"
            return ok
        }
        fileTransferMessage = "Sent \(url.lastPathComponent)"
        return true
    }

    public func handleIncomingNotification(_ notification: ContinuityNotification) {
        if let otp = OTPExtractor().extractOTP(from: "\(notification.title) \(notification.body)") {
            self.activeOTP = otp
        }
    }

    public func dismissOTP() { self.activeOTP = nil }
}
