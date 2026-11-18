import AppKit
import MirrorRenderer

/// One native mirror window: video, input, Android navigation buttons and file drop.
@MainActor
public final class MirrorWindowController: NSObject, NSWindowDelegate {
    public let mode: MirrorMode
    public var onClose: (() -> Void)?
    public var onStatus: ((String) -> Void)?

    private let phone: PhoneEndpoint
    private let adbPath: String
    private let config: NativeMirrorConfig
    private let client = ScrcpyStreamClient()
    private let sink = MirrorFrameSink()
    private let surface = MirrorMetalNSView()
    private let transferBar = TransferBar()
    private let files: FileDropQueue
    private var powerWatcher: PowerKeyWatcher?
    /// Desk mode only: the virtual display's id (from the server log) and the phone's apps.
    private var displayID: Int?
    private var apps: [PhoneApp]?
    private let recentApps = RecentApps()
    private let window: NSWindow

    public init(phone: PhoneEndpoint, adbPath: String, serverPath: String, mode: MirrorMode) {
        self.phone = phone
        self.adbPath = adbPath
        self.mode = mode
        self.config = NativeMirrorConfig(mode: mode, serverPath: serverPath)
        self.files = FileDropQueue(serial: phone.serial)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 800),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = mode == .panelOff ? phone.model : "\(phone.model) desk"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary]
        buildContent()
        window.addTitlebarAccessoryViewController(NavigationButtons.controller(
            buttons: NavigationButtons.Button.forMode(desk: mode != .panelOff),
            action: { [weak self] in self?.send($0) },
            appsMenu: { [weak self] in
                guard let self else { return NSMenu() }
                return NavigationButtons.appsMenu(apps: self.apps, recent: self.recentApps.packages) { [weak self] in
                    self?.open($0)
                }
            }))
    }

    public func show() {
        if case .desk(let w, let h, _) = mode { fit(CGSize(width: w, height: h)) }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        start()
    }

    public func close() { window.close() }

    // MARK: - Setup

    private func buildContent() {
        let content = NSView()
        surface.translatesAutoresizingMaskIntoConstraints = false
        transferBar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(surface)
        content.addSubview(transferBar)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            surface.topAnchor.constraint(equalTo: content.topAnchor),
            surface.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            transferBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            transferBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            transferBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            transferBar.heightAnchor.constraint(equalToConstant: TransferBar.height),
        ])
        window.contentView = content
        sink.attach(pipeline: surface.renderPipeline)
        let client = self.client
        surface.onControl = { client.sendControl($0) }
        surface.onDropFiles = { [weak self] urls in self?.files.enqueue(urls) }
        files.onEvent = { [weak self] in self?.transferBar.show($0) }
        transferBar.onStop = { [weak self] in self?.files.cancelAll() }
    }

    private func start() {
        let sink = self.sink
        client.onPixelBuffer = { buffer, _ in sink.submit(pixelBuffer: buffer) }
        client.onVideoDimensionsChanged = { [weak self] size in
            Task { @MainActor in self?.videoSizeChanged(size) }
        }
        client.onStateChanged = { [weak self] state in
            Task { @MainActor in self?.stateChanged(state) }
        }
        if mode != .panelOff {
            let log = LogScanner()
            client.onServerLog = { [weak self] chunk in
                guard let id = log.virtualDisplayID(after: chunk) else { return }
                Task { @MainActor in self?.displayID = id }
            }
        }
        let (client, phone, adbPath, config) = (self.client, self.phone, self.adbPath, self.config)
        Task {
            do {
                try await client.start(serial: phone.serial, adbPath: adbPath, maxSize: config.maxSize,
                                       maxFps: NativeMirrorConfig.maxFps, options: config.streamOptions)
            } catch {
                onStatus?("Mirror failed: \(error)")
                close()
            }
        }
        if config.turnsPanelOff { watchPowerKey() }
    }

    private func stateChanged(_ state: ScrcpyStreamClient.StreamState) {
        switch state {
        case .streaming:
            if config.turnsPanelOff { client.sendControl(ScrcpyControlEncoder.setDisplayPower(on: false)) }
            if mode != .panelOff, apps == nil { loadApps() }
        case .failed(let message):
            onStatus?("Mirror stopped: \(message.split(separator: "\n").last ?? "")")
            close()
        case .idle, .starting:
            break
        }
    }

    private func videoSizeChanged(_ size: CGSize) {
        let first = surface.videoSize == .zero
        surface.videoSize = size
        if first || window.contentAspectRatio != size { fit(size) }
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

    private func loadApps() {
        let (adb, serial) = (adbPath, phone.serial)
        Task {
            let list = (try? await PhoneApps.load(adb: adb, serial: serial)) ?? []
            self.apps = list
        }
    }

    private func open(_ app: PhoneApp) {
        recentApps.record(app.package)
        // START_APP opens the app on this session's display.
        client.sendControl(ScrcpyControlEncoder.startApp(packageName: app.package))
    }

    private func send(_ button: NavigationButtons.Button) {
        switch button {
        case .home where mode != .panelOff:
            // The Home key is dropped while the phone is locked; start the desktop home instead.
            guard let displayID else { return }
            _ = try? Process.run(URL(fileURLWithPath: adbPath),
                                 arguments: PhoneApps.homeArguments(serial: phone.serial, displayId: displayID))
        case .apps:
            break
        case .back: client.sendControl(ScrcpyControlEncoder.tapKeycode(ScrcpyControlEncoder.AndroidKeyCode.back.rawValue))
        case .home: client.sendControl(ScrcpyControlEncoder.tapKeycode(ScrcpyControlEncoder.AndroidKeyCode.home.rawValue))
        case .recents: client.sendControl(ScrcpyControlEncoder.tapKeycode(ScrcpyControlEncoder.AndroidKeyCode.appSwitch.rawValue))
        case .notifications: client.sendControl(ScrcpyControlEncoder.expandNotificationPanel())
        }
    }

    // MARK: - Power key

    private func watchPowerKey() {
        let watcher = PowerKeyWatcher(adbPath: adbPath, serial: phone.serial)
        let (adb, serial) = (adbPath, phone.serial)
        watcher.onPress = { [weak self] in
            // The press already put the phone to sleep. Wake it so the panel lights up, then
            // end the session: the user has picked up the phone.
            _ = try? Process.run(URL(fileURLWithPath: adb), arguments: ["-s", serial, "shell", "input", "keyevent", "KEYCODE_WAKEUP"])
            Task { @MainActor in self?.close() }
        }
        do {
            try watcher.start()
            powerWatcher = watcher
        } catch {
            onStatus?("Power key watch failed: \(error)")
        }
    }

    // MARK: - NSWindowDelegate

    public func windowWillClose(_ notification: Notification) {
        powerWatcher?.stop()
        powerWatcher = nil
        files.cancelAll()
        client.stop()
        sink.attach(pipeline: nil)
        onClose?()
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
