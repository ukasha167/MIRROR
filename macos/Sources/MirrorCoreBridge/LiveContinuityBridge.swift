import Foundation
import CoreGraphics

/// Production Continuity bridge requiring mutual app-level handshake before marking a phone connected.
/// USB cable detection (`adb devices`) sets up ADB reverse/forward tunnels and populates `usbAttachedDevice`,
/// but never elevates `sessionState` to `.connected` until the Android Mirror app responds and authenticates.
public actor LiveContinuityBridge: ContinuityBridgeProtocol {
    public var sessionState: ContinuitySessionState = .disconnected
    public var activeDevice: PairedDevice?
    public var pairedDevices: [PairedDevice] = []
    public private(set) var usbAttachedDevice: UsbAttachedDevice?

    public nonisolated let adbPath: String
    public nonisolated let hostServer: ContinuityHostServer

    private var isMirrorStreaming = false
    private var lastTunnelSerial: String?

    public init(adbPath: String = "/opt/homebrew/bin/adb", peerStore: PairedPeerStore = PairedPeerStore()) {
        if FileManager.default.isExecutableFile(atPath: adbPath) {
            self.adbPath = adbPath
        } else if FileManager.default.isExecutableFile(atPath: "/usr/local/bin/adb") {
            self.adbPath = "/usr/local/bin/adb"
        } else {
            self.adbPath = "adb"
        }
        let server = ContinuityHostServer(peerStore: peerStore)
        server.start()
        self.hostServer = server
    }

    public nonisolated func currentPairingInfo() -> (qrPayload: String, pin: String) {
        (hostServer.currentQrPayloadString(), hostServer.currentPairingPin())
    }

    public nonisolated func rotatePairingInfo() -> (qrPayload: String, pin: String) {
        let pin = hostServer.rotatePairingPin()
        return (hostServer.currentQrPayloadString(), pin)
    }

    /// Refreshes both physical USB cable presence (ADB) and mutual Continuity app handshake state.
    public func refreshConnectionState() async -> ContinuitySnapshot {
        let usbSerial = await runAdbDevicesSerial()
        if let usbSerial {
            let model = await readDeviceProperty(serial: usbSerial, prop: "ro.product.model") ?? "Android Device"
            let size = await readPhysicalScreenSize(serial: usbSerial)
            usbAttachedDevice = UsbAttachedDevice(serial: usbSerial, model: model, screenSize: size)
            hostServer.setLocalAdbSerial(usbSerial)
            await ensureAdbTunnels(serial: usbSerial)
            hostServer.probeUsbPeer(port: ContinuityHostServer.defaultAndroidPort)
        } else {
            usbAttachedDevice = nil
            lastTunnelSerial = nil
            hostServer.setLocalAdbSerial(nil)
        }

        let trusted = hostServer.peerStore.allPeers()
        let discovered = hostServer.snapshotDiscoveredPeers()

        if let verified = hostServer.snapshotConnectedPeer() {
            let paired = makePairedDevice(from: verified)
            self.activeDevice = paired
            self.pairedDevices = [paired]
            self.sessionState = isMirrorStreaming ? .streaming : .connected
        } else {
            self.activeDevice = nil
            self.pairedDevices = trusted.map {
                PairedDevice(id: $0.id, name: $0.name, model: $0.model, transport: .wifiLan, certificateFingerprint: $0.pairToken.prefix(16).description, connectionStatus: .disconnected)
            }
            self.sessionState = discovered.isEmpty ? .disconnected : .discovering
        }

        return ContinuitySnapshot(
            sessionState: sessionState,
            activeDevice: activeDevice,
            usbAttached: usbAttachedDevice,
            discoveredPeers: discovered,
            trustedPeers: trusted
        )
    }

    /// Backwards-compatible wrapper returning `activeDevice` ONLY when mutual app connection is live.
    public func refreshConnectedDevice() async -> PairedDevice? {
        let snapshot = await refreshConnectionState()
        return snapshot.activeDevice
    }

    public func startDiscovery() async throws {
        hostServer.start()
        _ = await refreshConnectionState()
    }

    public func stopDiscovery() async {
        self.sessionState = activeDevice != nil ? (isMirrorStreaming ? .streaming : .connected) : .disconnected
    }

    public func pairDevice(id: String, pin: String?) async throws -> Bool {
        guard let pin, !ContinuityPairingCodec.normalizePin(pin).isEmpty else {
            return false
        }
        _ = try await pairWithPhone(peerId: id.isEmpty ? nil : id, manualAddress: nil, pinCode: pin)
        return true
    }

    /// Initiates pairing from Mac using a 6-digit code displayed on Android.
    public func pairWithPhone(peerId: String?, manualAddress: String?, pinCode: String) async throws -> PairedDevice {
        sessionState = .pairing
        do {
            let verified = try await hostServer.pairWithPhone(peerId: peerId, manualAddress: manualAddress, pinCode: pinCode)
            let paired = makePairedDevice(from: verified)
            self.activeDevice = paired
            self.pairedDevices = [paired]
            self.sessionState = .connected
            return paired
        } catch {
            self.sessionState = activeDevice != nil ? .connected : .disconnected
            throw error
        }
    }

    /// Unpairs the given (or currently active) device and tears down trusted token state on Mac.
    public func unpairDevice(id: String? = nil) async {
        let targetId = id ?? activeDevice?.id
        if let targetId {
            hostServer.unpair(deviceId: targetId)
        }
        if activeDevice?.id == targetId || id == nil {
            activeDevice = nil
            isMirrorStreaming = false
            sessionState = .disconnected
        }
        _ = await refreshConnectionState()
    }

    public func disconnect() async {
        hostServer.disconnectActiveSession()
        isMirrorStreaming = false
        activeDevice = nil
        sessionState = .disconnected
    }

    public func sendClipboard(item: ClipboardItem) async throws {
        guard activeDevice != nil, let rawText = item.inlineText, !rawText.isEmpty else { return }
        hostServer.sendClipboardText(rawText)
        if let serial = resolveAdbSerial() {
            _ = await runProcess(executable: adbPath, arguments: ["-s", serial, "shell", "cmd", "clipboard", "set", rawText])
        }
    }

    public func fetchLazyClipboardData(metadata: LazyClipboardMetadata) async throws -> Data {
        guard let serial = resolveAdbSerial() else { return Data() }
        let output = await runProcess(executable: adbPath, arguments: ["-s", serial, "shell", "cmd", "clipboard", "get"]) ?? ""
        return output.data(using: .utf8) ?? Data()
    }

    public func dismissNotification(id: String) async throws {}
    public func sendNotificationReply(id: String, text: String) async throws {}

    /// Marks mirroring active (actual H.265/H.264 stream & Metal surface run inline via `ScrcpyStreamClient` inside the window).
    public func startMirroring(deviceId: String, appPackage: String?) async throws {
        guard activeDevice != nil else { return }
        isMirrorStreaming = true
        sessionState = .streaming
    }

    public func stopMirroring() async throws {
        isMirrorStreaming = false
        sessionState = activeDevice != nil ? .connected : .disconnected
    }

    public func resolveAdbSerial() -> String? {
        guard activeDevice != nil else { return nil }
        if let verifiedSerial = hostServer.snapshotConnectedPeer()?.adbSerial, !verifiedSerial.isEmpty {
            return verifiedSerial
        }
        return usbAttachedDevice?.serial
    }

    public func pushFile(localPath: String) async throws -> Bool {
        guard let serial = resolveAdbSerial() else { return false }
        let result = await runProcess(executable: adbPath, arguments: ["-s", serial, "push", localPath, "/sdcard/Download/"])
        return result?.contains("pushed") == true
    }

    // MARK: - Private ADB Helpers (Safe Argument-Array Execution)

    private func ensureAdbTunnels(serial: String) async {
        if lastTunnelSerial != serial {
            lastTunnelSerial = serial
        }
        let macPort = hostServer.boundPort
        _ = await runProcess(executable: adbPath, arguments: ["-s", serial, "reverse", "tcp:53318", "tcp:\(macPort)"])
        _ = await runProcess(executable: adbPath, arguments: ["-s", serial, "forward", "tcp:\(ContinuityHostServer.defaultAndroidPort)", "tcp:\(ContinuityHostServer.defaultAndroidPort)"])
    }

    private func makePairedDevice(from verified: VerifiedConnectedPeer) -> PairedDevice {
        PairedDevice(
            id: verified.id,
            name: verified.name,
            model: verified.model,
            transport: verified.isUsb ? .usbAdb : .wifiLan,
            certificateFingerprint: "verified-\(verified.id.prefix(12))",
            batteryLevel: Double(max(0, min(100, verified.batteryLevel))) / 100.0,
            isCharging: verified.isCharging,
            connectionStatus: .connected,
            ipAddress: verified.isUsb ? "127.0.0.1" : "",
            port: ContinuityHostServer.defaultAndroidPort
        )
    }

    private func runAdbDevicesSerial() async -> String? {
        guard let output = await runProcess(executable: adbPath, arguments: ["devices"]) else { return nil }
        for line in output.components(separatedBy: .newlines).dropFirst() {
            let parts = line.split(whereSeparator: \.isWhitespace)
            if parts.count >= 2 && parts[1] == "device" {
                return String(parts[0])
            }
        }
        return nil
    }

    private func readDeviceProperty(serial: String, prop: String) async -> String? {
        guard let output = await runProcess(executable: adbPath, arguments: ["-s", serial, "shell", "getprop", prop]) else {
            return nil
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func readPhysicalScreenSize(serial: String) async -> CGSize? {
        guard let output = await runProcess(executable: adbPath, arguments: ["-s", serial, "shell", "wm", "size"]) else {
            return nil
        }
        for line in output.components(separatedBy: .newlines).reversed() {
            guard let range = line.range(of: ": ") else { continue }
            let dim = line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = dim.split(separator: "x")
            if parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]), w > 0, h > 0 {
                return CGSize(width: w, height: h)
            }
        }
        return nil
    }

    private func runProcess(executable: String, arguments: [String]) async -> String? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: executable)
                proc.arguments = arguments
                let pipe = Pipe()
                proc.standardOutput = pipe
                proc.standardError = Pipe()
                do {
                    try proc.run()
                    proc.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    cont.resume(returning: String(data: data, encoding: .utf8))
                } catch {
                    cont.resume(returning: nil)
                }
            }
        }
    }
}
