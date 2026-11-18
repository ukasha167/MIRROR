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
    /// Latest file push event, for the menu bar. `.idle` once the last message has been shown.
    @Published public private(set) var transfer: FileDropQueue.Event = .idle
    @Published public var clipboardEnabled = true {
        didSet { clipboardEnabled ? startClipboardIfNeeded() : stopClipboard() }
    }

    public enum WindowKind: Hashable, Sendable {
        case desk, panelOff
        /// One phone app on its own virtual display.
        case app(String)
    }

    /// Seconds between `adb devices` checks. Each check is one short adb process.
    static let refreshInterval: UInt64 = 5

    private var adb: AdbClient?
    private var server: ScrcpyServer?
    private var clipboard: ClipboardBridge?
    private var clipboardSerial: String?
    private var windows: [WindowKind: MirrorWindowController] = [:]
    private var refreshTask: Task<Void, Never>?
    private let quickShareReceiver = QuickShareReceiver()
    private let target = TransferTarget()
    private let files: FileDropQueue
    private var transferClear: Task<Void, Never>?

    /// Push cap over Wi-Fi while a mirror window is open: half of the 6 MB/s that adb over
    /// Wi-Fi measured on the test network, leaving room for the 1 MB/s video.
    public static let wifiPushLimitWithMirror = 3_000_000

    public init() {
        let target = self.target
        files = FileDropQueue { url, progress in
            let serial = target.snapshot.serial
            return try AdbSyncPush(serial: serial, rateLimit: { target.snapshot.limit }).push(url, progress: progress)
        }
        files.onEvent = { [weak self] in self?.transferChanged($0) }
        files.onRetry = { [weak self] in Task { await self?.refresh() } }
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
            let switchedToUsb = phone?.serial != found.serial && found.transport == .usb && phone?.transport == .wifi
            phone = found
            updateTarget()
            // A push over Wi-Fi starts again over the cable, about 30 times faster here.
            if switchedToUsb, files.isSending { files.restartCurrent() }
            windows.values.forEach { $0.use(found) }
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

    // MARK: - File transfers

    /// Files dropped on any mirror window. They go to the phone's Download folder in order.
    public func send(_ urls: [URL]) {
        updateTarget()
        files.enqueue(urls)
    }

    public func stopSending() { files.cancelAll() }

    private func transferChanged(_ event: FileDropQueue.Event) {
        transferClear?.cancel()
        if event == .idle {
            // Leave "sent" or "not sent" in the menu for a while, then clear it.
            transferClear = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if !Task.isCancelled { self?.transfer = .idle }
            }
        } else {
            transfer = event
        }
    }

    private func updateTarget() {
        guard let phone else { return }
        let limited = phone.transport == .wifi && !windows.isEmpty
        target.set(serial: phone.serial, limit: limited ? Self.wifiPushLimitWithMirror : nil)
    }

    /// Short menu bar title while sending, such as "42%".
    public var transferBadge: String? {
        if case .progress(let status) = transfer { return "\(Int(status.fraction * 100))%" }
        return nil
    }

    /// Menu line for the transfer, or nil when there is nothing to show.
    public var transferLabel: String? {
        switch transfer {
        case .idle: return nil
        case .progress(let s):
            let more = s.queued > 0 ? " (+\(s.queued) more)" : ""
            let via = phone?.transport == .usb ? "USB" : "Wi-Fi"
            return "Sending \(s.fileName)\(more): \(Self.bytes(s.sent)) of \(Self.bytes(s.total)) over \(via)"
        case .finished(let name, _): return "\(name) is in Download on the phone"
        case .failed(let name, let message): return "\(name) not sent: \(message)"
        }
    }

    public var isSending: Bool { if case .progress = transfer { true } else { false } }

    static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    // MARK: - Mirror windows (continued)

    public func toggle(_ kind: WindowKind) {
        if let window = windows[kind] {
            window.close()
            return
        }
        open(kind, app: nil)
    }

    /// Opens `app` in its own window, or brings its window to the front.
    public func openAppWindow(_ app: PhoneApp) {
        if let window = windows[.app(app.package)] {
            window.window.makeKeyAndOrderFront(nil)
            return
        }
        open(.app(app.package), app: app)
    }

    private func open(_ kind: WindowKind, app: PhoneApp?) {
        guard let phone, let server, let adb else { return }
        let mode: MirrorMode = kind == .panelOff ? .panelOff : .defaultDesk
        let window = MirrorWindowController(phone: phone, adbPath: adb.adbPath, serverPath: server.path, mode: mode, app: app)
        window.onOpenAppWindow = { [weak self] in self?.openAppWindow($0) }
        window.onClose = { [weak self] in
            self?.windows[kind] = nil
            self?.openWindows.remove(kind)
            self?.updateTarget()
        }
        window.onStatus = { [weak self] in self?.status = $0 }
        window.onDropFiles = { [weak self] in self?.send($0) }
        // The stream broke (cable pulled, Wi-Fi dropped): look for the phone now rather than
        // at the next 5 s check. `refresh` hands the endpoint to the window.
        window.onLost = { [weak self] in Task { await self?.refresh() } }
        windows[kind] = window
        openWindows.insert(kind)
        updateTarget()
        window.show()
    }

    public func shutdown() {
        refreshTask?.cancel()
        windows.values.forEach { $0.close() }
        files.cancelAll()
        stopClipboard()
    }
}

/// Where a push goes and how fast, read by the push thread when a file starts and per chunk.
final class TransferTarget: @unchecked Sendable {
    private let lock = NSLock()
    private var serial = ""
    private var limit: Int?

    func set(serial: String, limit: Int?) {
        lock.withLock {
            self.serial = serial
            self.limit = limit
        }
    }

    var snapshot: (serial: String, limit: Int?) { lock.withLock { (serial, limit) } }
}
