import AppKit
import MirrorRenderer

/// One native mirror window: video, input, Android navigation buttons and file drop.
///
/// The window stays open until the user closes it. When the stream breaks (cable pulled,
/// Wi-Fi drop, phone restart) it shows "Reconnecting" and starts a new session as soon as the
/// controller hands it an endpoint through `use(_:)`, over USB or Wi-Fi.
@MainActor
public final class MirrorWindowController: NSObject, NSWindowDelegate {
    public let mode: MirrorMode
    public var onClose: (() -> Void)?
    public var onStatus: ((String) -> Void)?
    public var onDropFiles: (([URL]) -> Void)?
    /// The stream broke. The owner should look for the phone and call `use(_:)`.
    public var onLost: (() -> Void)?
    /// Desk launcher: the user asked for an app in its own window.
    public var onOpenAppWindow: ((PhoneApp) -> Void)?
    /// Set for a window that shows one app on its own virtual display, with no launcher.
    public let soloApp: PhoneApp?

    private(set) var phone: PhoneEndpoint
    private let adbPath: String
    let serverPath: String
    let client = ScrcpyStreamClient()
    private let sink = MirrorFrameSink()
    let surface = MirrorMetalNSView()
    private let statusLabel = NSTextField(labelWithString: "")
    let window: NSWindow
    private var powerWatcher: PowerKeyWatcher?
    private enum Link { case connecting, streaming, lost }
    private var link = Link.connecting
    private var closing = false
    private var retryTask: Task<Void, Never>?
    /// Panel-off mode: true until the user presses the phone's power key. Then the phone's
    /// panel stays on, including after a reconnect.
    private var panelOffWanted = true

    // Desk mode state (see MirrorWindowController+Desk.swift).
    let apps = DeskAppsModel()
    var displayID: Int?
    /// The app last opened on the virtual display, reopened after a reconnect.
    var lastApp: String?
    var resizeWork: DispatchWorkItem?
    var launcherObserver: Any?
    var overviewObserver: Any?

    public init(phone: PhoneEndpoint, adbPath: String, serverPath: String, mode: MirrorMode, app: PhoneApp? = nil) {
        self.soloApp = app
        self.phone = phone
        self.adbPath = adbPath
        self.serverPath = serverPath
        self.mode = mode
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 800),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = app?.name ?? (isDesk ? "\(phone.model) desk" : phone.model)
        lastApp = app?.package
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary]
        if soloApp != nil || !isDesk { buildPhoneContent() } else { buildDeskContent() }
        connectInput()
        window.addTitlebarAccessoryViewController(NavigationButtons.controller(
            buttons: app != nil ? [.back] : NavigationButtons.Button.forMode(desk: isDesk),
            action: { [weak self] in self?.send($0) }))
    }

    var isDesk: Bool { mode != .panelOff }

    public func show() {
        if isDesk { sizeDeskWindow() }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        startSession()
    }

    public func close() { window.close() }

    /// The controller found the phone. Starts a session when the stream is down or the phone
    /// moved to another transport (USB plugged in: switch to the faster cable).
    public func use(_ endpoint: PhoneEndpoint) {
        guard !closing else { return }
        guard endpoint.serial != phone.serial || link == .lost else { return }
        phone = endpoint
        startSession()
    }

    // MARK: - Layout

    private func buildPhoneContent() {
        let content = NSView()
        pin(surface, in: content)
        window.contentView = content
        addStatusLabel(over: content)
    }

    func pin(_ view: NSView, in parent: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            view.topAnchor.constraint(equalTo: parent.topAnchor),
            view.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
        ])
    }

    func addStatusLabel(over parent: NSView) {
        statusLabel.font = .systemFont(ofSize: 15, weight: .medium)
        statusLabel.textColor = .white
        statusLabel.alignment = .center
        statusLabel.isHidden = true
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: surface.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: surface.centerYAnchor),
            statusLabel.widthAnchor.constraint(lessThanOrEqualTo: surface.widthAnchor, constant: -40),
        ])
    }

    private func connectInput() {
        sink.attach(pipeline: surface.renderPipeline)
        let client = self.client
        surface.onControl = { client.sendControl($0) }
        surface.onDropFiles = { [weak self] urls in self?.onDropFiles?(urls) }
        let sink = self.sink
        client.onPixelBuffer = { buffer, _ in sink.submit(pixelBuffer: buffer) }
        client.onVideoDimensionsChanged = { [weak self] size in
            Task { @MainActor in self?.videoSizeChanged(size) }
        }
        client.onStateChanged = { [weak self] state in
            Task { @MainActor in self?.stateChanged(state) }
        }
    }

    // MARK: - Session

    private func startSession() {
        retryTask?.cancel()
        retryTask = nil
        link = .connecting
        showStatus("Connecting over \(phone.transport == .usb ? "USB" : "Wi-Fi")...")
        let config = NativeMirrorConfig(mode: currentMode, serverPath: serverPath, transport: phone.transport,
                                        soloApp: soloApp != nil)
        if isDesk {
            displayID = nil
            let log = LogScanner()
            client.onServerLog = { [weak self] chunk in
                guard let id = log.virtualDisplayID(after: chunk) else { return }
                Task { @MainActor in self?.displayID = id }
            }
        }
        let (client, phone, adbPath, reopen) = (self.client, self.phone, self.adbPath, isDesk ? lastApp : nil)
        Task {
            do {
                try await client.start(serial: phone.serial, adbPath: adbPath, maxSize: config.maxSize,
                                       maxFps: NativeMirrorConfig.maxFps, initialPackage: reopen,
                                       options: config.streamOptions)
            } catch {
                lost("\(error)")
            }
        }
        if config.turnsPanelOff { watchPowerKey() }
    }

    private func stateChanged(_ state: ScrcpyStreamClient.StreamState) {
        guard !closing else { return }
        switch state {
        case .streaming:
            if link != .streaming { sessionStarted() }
        case .failed(let message):
            lost(String(message.split(separator: "\n").last ?? ""))
        case .idle, .starting:
            break
        }
    }

    private func sessionStarted() {
        link = .streaming
        showStatus(nil)
        if mode == .panelOff, panelOffWanted {
            client.sendControl(ScrcpyControlEncoder.setDisplayPower(on: false))
        }
        if isDesk { deskSessionStarted() }
    }

    /// Keeps the window and tries again every 3 s until a session starts or the window closes.
    private func lost(_ reason: String) {
        guard !closing, link != .lost else { return }
        link = .lost
        powerWatcher?.stop()
        powerWatcher = nil
        client.stop()
        showStatus("Phone disconnected. Reconnecting...")
        onStatus?("Mirror lost the phone: \(reason)")
        retryTask = Task { [weak self] in
            // Give adb a second to drop the dead transport, then ask every 3 s.
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            while !Task.isCancelled {
                self?.onLost?()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    private func showStatus(_ text: String?) {
        statusLabel.stringValue = text ?? ""
        statusLabel.isHidden = text == nil
    }

    private func videoSizeChanged(_ size: CGSize) {
        let first = surface.videoSize == .zero
        surface.videoSize = size
        // Desk mode: the window sets the display's size, not the other way round.
        if !isDesk, first || window.contentAspectRatio != size { fit(size) }
    }

    /// Sizes the window to the video's shape, as large as 85% of the screen allows.
    private func fit(_ video: CGSize) {
        guard video.width > 0, video.height > 0 else { return }
        window.contentAspectRatio = video
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let scale = min(screen.width * 0.85 / video.width, screen.height * 0.85 / video.height)
        let size = CGSize(width: (video.width * scale).rounded(), height: (video.height * scale).rounded())
        let old = window.frame
        window.setContentSize(size)
        // Keep the window's centre where it was when the phone rotates.
        let new = window.frame
        window.setFrameOrigin(NSPoint(x: old.midX - new.width / 2, y: old.midY - new.height / 2))
    }

    private func send(_ button: NavigationButtons.Button) {
        if isDesk, deskHandles(button) { return }
        switch button {
        case .back: client.sendControl(ScrcpyControlEncoder.tapKeycode(ScrcpyControlEncoder.AndroidKeyCode.back.rawValue))
        case .home: client.sendControl(ScrcpyControlEncoder.tapKeycode(ScrcpyControlEncoder.AndroidKeyCode.home.rawValue))
        case .recents: client.sendControl(ScrcpyControlEncoder.tapKeycode(ScrcpyControlEncoder.AndroidKeyCode.appSwitch.rawValue))
        case .notifications: client.sendControl(ScrcpyControlEncoder.expandNotificationPanel())
        case .apps: break
        }
    }

    func runAdb(_ arguments: [String]) {
        _ = try? Process.run(URL(fileURLWithPath: adbPath), arguments: arguments)
    }

    var adb: String { adbPath }

    // MARK: - Power key

    /// Panel-off mode. A power press puts the phone to sleep while its panel is already dark,
    /// so the user sees nothing (Phase 1 hand test). The first press wakes the phone and turns
    /// its panel on; the mirror keeps running. Later presses are left alone, so the user can
    /// still put the phone to sleep.
    private func watchPowerKey() {
        powerWatcher?.stop()
        guard panelOffWanted else { return }
        let watcher = PowerKeyWatcher(adbPath: adbPath, serial: phone.serial)
        watcher.onPress = { [weak self] in
            Task { @MainActor in self?.powerPressed() }
        }
        do {
            try watcher.start()
            powerWatcher = watcher
        } catch {
            onStatus?("Power key watch failed: \(error)")
        }
    }

    private func powerPressed() {
        guard panelOffWanted else { return }
        panelOffWanted = false
        powerWatcher?.stop()
        powerWatcher = nil
        runAdb(["-s", phone.serial, "shell", "input", "keyevent", "KEYCODE_WAKEUP"])
        client.sendControl(ScrcpyControlEncoder.setDisplayPower(on: true))
    }

    // MARK: - NSWindowDelegate

    public func windowWillClose(_ notification: Notification) {
        closing = true
        retryTask?.cancel()
        powerWatcher?.stop()
        powerWatcher = nil
        resizeWork?.cancel()
        client.stop()
        sink.attach(pipeline: nil)
        onClose?()
    }

    public func windowDidResize(_ notification: Notification) {
        if isDesk { deskWindowResized() }
    }
}

/// Collects server output until the virtual display id shows up.
final class LogScanner: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    private var found = false

    func virtualDisplayID(after chunk: String) -> Int? {
        lock.withLock {
            guard !found else { return nil }
            text += chunk
            guard let id = PhoneApps.virtualDisplayID(inServerLog: text) else { return nil }
            found = true
            text = ""
            return id
        }
    }
}
