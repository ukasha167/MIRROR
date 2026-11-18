import Foundation
import AppKit
import Combine

/// Drives the menu bar: finds the phone, keeps clipboard sync running, opens mirror windows.
@MainActor
public final class DeskController: ObservableObject {
    @Published public private(set) var phone: PhoneEndpoint?
    @Published public private(set) var status = "Looking for phone..."
    @Published public private(set) var openWindows: Set<WindowKind> = []
    @Published public private(set) var clipboardActive = false
    @Published public private(set) var quickShare: QuickShareReceiver.State = .off
    @Published public var clipboardEnabled = true {
        didSet { clipboardEnabled ? startClipboardIfNeeded() : stopClipboard() }
    }

    public enum WindowKind: Hashable, Sendable { case desk, panelOff }

    /// Seconds between `adb devices` checks. Each check is one short adb process.
    static let refreshInterval: UInt64 = 5

    private var adb: AdbClient?
    private var server: ScrcpyServer?
    private var clipboard: ClipboardBridge?
    private var clipboardSerial: String?
    private var windows: [WindowKind: MirrorWindowController] = [:]
    private var refreshTask: Task<Void, Never>?
    private let quickShareReceiver = QuickShareReceiver()

    public init() {
        quickShareReceiver.onChange = { [weak self] in self?.quickShare = $0 }
        quickShareReceiver.start()
        refreshTask = Task { [weak self] in
            await self?.setUpTools()
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: Self.refreshInterval * 1_000_000_000)
            }
        }
    }

    /// One line for the menu, such as "Quick Share: receiving photo.jpg from Pixel 7 Pro".
    public var quickShareLabel: String {
        switch quickShare {
        case .off: "Quick Share: off"
        case .visible: "Quick Share: visible as \(Host.current().localizedName ?? "this Mac")"
        case .waiting(let device, let summary): "Quick Share: \(device) wants to send \(summary)"
        case .receiving(let device, let summary): "Quick Share: receiving \(summary) from \(device)"
        case .received(let summary): "Quick Share: received \(summary)"
        case .failed(let device, let message): "Quick Share from \(device) failed: \(message)"
        }
    }

    public var phoneLabel: String {
        guard let phone else { return status }
        return "\(phone.model) (\(phone.transport == .usb ? "USB" : "Wi-Fi"))"
    }

    // MARK: - Setup

    private func setUpTools() async {
        do {
            let adbPath = try ToolLocator.find("adb")
            adb = AdbClient(adbPath: adbPath)
            // The scrcpy client is only asked for its version, which picks our server build.
            let scrcpy = try ToolLocator.find("scrcpy")
            let out = try await ProcessCommandRunner().run(scrcpy, ["--version"])
            guard let version = ScrcpyServer.parseClientVersion(out.stdout) else {
                status = "Could not read scrcpy version"
                return
            }
            server = ScrcpyServer.locate(clientVersion: version)
            if server == nil {
                status = "No patched server for scrcpy \(version). Run scripts/build-scrcpy-server.sh"
            }
        } catch {
            status = "\(error)"
        }
    }

    public func refresh() async {
        guard let adb else { return }
        do {
            let found = try await PhoneLocator(adb: adb).locate()
            phone = found
            if server != nil { status = "Ready" }
            if clipboardSerial != nil && clipboardSerial != found.serial {
                // USB was unplugged (or plugged in): move clipboard sync to the new transport.
                stopClipboard()
            }
            startClipboardIfNeeded()
        } catch {
            phone = nil
            status = "\(error)"
            stopClipboard()
        }
    }

    // MARK: - Clipboard

    private func startClipboardIfNeeded() {
        guard clipboardEnabled, clipboard == nil, let adb, let server, let phone else { return }
        let session = ScrcpyControlSession(adb: adb, serial: phone.serial, server: server)
        let bridge = ClipboardBridge(session: session)
        bridge.onStatus = { [weak self] message in
            // The session died (phone gone, server killed). The next refresh starts a new one.
            self?.clipboard = nil
            self?.clipboardSerial = nil
            self?.clipboardActive = false
            self?.status = message
        }
        clipboard = bridge
        clipboardSerial = phone.serial
        Task {
            do {
                try await bridge.start()
                clipboardActive = true
            } catch {
                clipboard = nil
                clipboardSerial = nil
                status = "Clipboard sync failed: \(error)"
            }
        }
    }

    private func stopClipboard() {
        clipboard?.stop()
        clipboard = nil
        clipboardSerial = nil
        clipboardActive = false
    }

    // MARK: - Mirror windows

    public func toggle(_ kind: WindowKind) {
        if let window = windows[kind] {
            window.close()
            return
        }
        guard let phone, let server, let adb else { return }
        let mode: MirrorMode = kind == .desk ? .defaultDesk : .panelOff
        let window = MirrorWindowController(phone: phone, adbPath: adb.adbPath, serverPath: server.path, mode: mode)
        window.onClose = { [weak self] in
            self?.windows[kind] = nil
            self?.openWindows.remove(kind)
        }
        window.onStatus = { [weak self] in self?.status = $0 }
        windows[kind] = window
        openWindows.insert(kind)
        window.show()
    }

    public func shutdown() {
        refreshTask?.cancel()
        windows.values.forEach { $0.close() }
        stopClipboard()
    }
}
