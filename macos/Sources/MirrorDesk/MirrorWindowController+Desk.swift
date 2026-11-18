import AppKit
import Combine
import MirrorRenderer
import SwiftUI

/// Desk mode: a virtual display sized to the window, a Mac-drawn launcher and dock.
extension MirrorWindowController {
    /// Video area plus dock, then the launcher over the video.
    func buildDeskContent() {
        let content = NSView()
        let dock = NSHostingView(rootView: DeskDockView(model: apps))
        let launcher = NSHostingView(rootView: DeskLauncherView(model: apps))
        for view in [surface, dock, launcher] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            surface.topAnchor.constraint(equalTo: content.topAnchor),
            surface.bottomAnchor.constraint(equalTo: dock.topAnchor),
            dock.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            dock.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            dock.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            dock.heightAnchor.constraint(equalToConstant: DeskDockView.height),
            launcher.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            launcher.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            launcher.topAnchor.constraint(equalTo: surface.topAnchor),
            launcher.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
        ])
        window.contentView = content
        window.contentMinSize = NSSize(width: 480, height: 360)
        addStatusLabel(over: content)
        apps.open = { [weak self] in self?.open($0) }
        launcherObserver = apps.$launcherShown.sink { [weak self, weak launcher] shown in
            launcher?.isHidden = !shown
            if !shown, let self { self.window.makeFirstResponder(self.surface) }
        }
    }

    /// 1100 x 688 points of video (16:10) or 70% of the screen, whichever is smaller.
    func sizeDeskWindow() {
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let width = min(1100, screen.width * 0.7)
        let video = CGSize(width: width.rounded(), height: (width * 10 / 16).rounded())
        window.setContentSize(NSSize(width: video.width, height: video.height + DeskDockView.height))
    }

    /// Desk mode sized to the video area as it is now, so a reconnect keeps the window's shape.
    var currentMode: MirrorMode {
        guard isDesk else { return .panelOff }
        window.contentView?.layoutSubtreeIfNeeded()
        let points = surface.bounds.size
        guard points.width > 0, points.height > 0 else { return mode }
        let px = MirrorMode.deskPixels(forPoints: points)
        return .desk(width: px.width, height: px.height, dpi: MirrorMode.deskDpi)
    }

    func deskSessionStarted() {
        if apps.apps == nil { loadApps() }
        // A reconnect reopened the last app (`initialPackage`); otherwise the display shows
        // only wallpaper while the phone is locked, so start on the launcher.
        if lastApp == nil { apps.launcherShown = true }
    }

    func loadApps() {
        let (adb, serial, server) = (self.adb, phone.serial, serverPath)
        Task {
            do {
                apps.setApps(try await PhoneApps.load(adb: adb, serial: serial, serverPath: server))
            } catch {
                apps.setApps([])
                onStatus?("Could not list phone apps: \(error)")
            }
        }
    }

    func open(_ app: PhoneApp) {
        lastApp = app.package
        // START_APP opens the app on this session's display, or brings its task to the front.
        client.sendControl(ScrcpyControlEncoder.startApp(packageName: app.package))
    }

    /// Returns true when desk mode handled the button itself.
    func deskHandles(_ button: NavigationButtons.Button) -> Bool {
        switch button {
        case .home:
            // The Home key is dropped while the phone is locked: start the desktop home (which
            // sends the current app to the background) and show the Mac launcher over it.
            lastApp = nil
            apps.launcherShown = true
            if let displayID { runAdb(PhoneApps.homeArguments(serial: phone.serial, displayId: displayID)) }
            return true
        case .apps:
            apps.launcherShown.toggle()
            return true
        default:
            return false
        }
    }

    /// Resizes the virtual display to the new video area once the user stops dragging for
    /// 150 ms. The server debounces too, but each resize restarts the encoder.
    func deskWindowResized() {
        resizeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, case .desk(let w, let h, _) = self.currentMode else { return }
            self.client.sendControl(ScrcpyControlEncoder.resizeDisplay(width: w, height: h))
        }
        resizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
}
