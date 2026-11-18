import Foundation
import Testing
@testable import MirrorDesk
@testable import MirrorRenderer

struct PinchTranslatorTests {
    @Test("A pinch puts two fingers around the cursor and spreads them as it grows")
    func spread() {
        var pinch = PinchTranslator(screen: CGSize(width: 1080, height: 2400))
        let down = pinch.handle(phase: .began, location: CGPoint(x: 540, y: 1200), magnification: 0)
        #expect(down.map(\.action) == [.down, .down])
        #expect(down.map(\.point.x) == [390, 690])
        #expect(Set(down.map(\.pointerId)).count == 2)
        let move = pinch.handle(phase: .changed, location: .zero, magnification: 0.5)
        #expect(move.map(\.point.x) == [315, 765])
        #expect(move.allSatisfy { $0.point.y == 1200 })
        let up = pinch.handle(phase: .ended, location: .zero, magnification: 0)
        #expect(up.map(\.action) == [.up, .up])
        #expect(pinch.handle(phase: .changed, location: .zero, magnification: 0.1).isEmpty)
    }

    @Test("Fingers stay on the screen and never meet")
    func clamps() {
        var pinch = PinchTranslator(screen: CGSize(width: 1080, height: 2400))
        _ = pinch.handle(phase: .began, location: CGPoint(x: 100, y: 500), magnification: 0)
        let wide = pinch.handle(phase: .changed, location: .zero, magnification: 5)
        #expect(wide.map(\.point.x) == [0, 200])
        let narrow = pinch.handle(phase: .changed, location: .zero, magnification: -0.99)
        #expect(narrow[1].point.x - narrow[0].point.x == PinchTranslator.minSpan)
    }
}

struct DeskSizingTests {
    @Test("Resize message is type 21 then width and height as big-endian u16")
    func resizeWire() {
        #expect(ScrcpyControlEncoder.resizeDisplay(width: 1650, height: 1032) == Data([21, 0x06, 0x72, 0x04, 0x08]))
    }

    @Test("Window points become even display pixels, capped at 2560 on the long side")
    func pixels() {
        #expect(MirrorMode.deskPixels(forPoints: CGSize(width: 1100, height: 688)) == (1650, 1032))
        #expect(MirrorMode.deskPixels(forPoints: CGSize(width: 801, height: 501)) == (1200, 750))
        let big = MirrorMode.deskPixels(forPoints: CGSize(width: 3000, height: 1500))
        #expect(big.width == 2560 && big.height == 1280)
    }

    @Test("Desk mode asks for a resizable display; Wi-Fi halves the video bit rate")
    func flexAndBitRate() {
        let desk = NativeMirrorConfig(mode: .defaultDesk, serverPath: "/s", transport: .wifi)
        #expect(desk.serverArguments.contains("flex_display=true"))
        #expect(desk.serverArguments.contains("new_display=1600x1000/240"))
        #expect(desk.streamOptions.videoBitRate == 8_000_000)
        #expect(NativeMirrorConfig(mode: .panelOff, serverPath: "/s", transport: .usb).videoBitRate == 16_000_000)
    }
}

struct AppCatalogTests {
    @Test("App list runs its own jar copy, keeps it, and asks for icons")
    func listArgs() {
        let args = PhoneApps.listArguments(serial: "S")
        #expect(args.contains("CLASSPATH=\(PhoneApps.listJar)"))
        #expect(args.contains("cleanup=false"))
        #expect(args.contains("app_icons_dir=\(PhoneApps.remoteIconDir)"))
        #expect(PhoneApps.listJar != "/data/local/tmp/scrcpy-server.jar")
    }

    @MainActor
    @Test("Launcher search matches any part of the name; the dock lists opened apps newest first")
    func model() {
        UserDefaults.standard.removeObject(forKey: RecentApps.key)
        defer { UserDefaults.standard.removeObject(forKey: RecentApps.key) }
        let model = DeskAppsModel()
        var opened: [String] = []
        model.open = { opened.append($0.package) }
        let chrome = PhoneApp(name: "Chrome", package: "c", isSystem: true)
        let clock = PhoneApp(name: "Clock", package: "k", isSystem: true)
        model.setApps([chrome, clock])
        model.query = "ock"
        #expect(model.filtered == [clock])
        model.launch(chrome)
        model.launch(clock)
        #expect(opened == ["c", "k"])
        #expect(model.dockApps == [clock, chrome])
        #expect(!model.launcherShown)
        #expect(model.query.isEmpty)
    }
}

struct PacerTests {
    @Test("Pacing holds a push near its byte rate; no rate means no wait")
    func rate() {
        var pacer = Pacer()
        let start = Date()
        for _ in 0..<5 {
            pacer.wait(rate: 1_000_000)
            pacer.sent(50_000)
        }
        pacer.wait(rate: 1_000_000)
        // 250 KB at 1 MB/s is 0.25 s.
        #expect(Date().timeIntervalSince(start) >= 0.24)

        var free = Pacer()
        let quick = Date()
        for _ in 0..<5 {
            free.wait(rate: nil)
            free.sent(50_000_000)
        }
        #expect(Date().timeIntervalSince(quick) < 0.05)
    }
}

@MainActor
struct FileDropRestartTests {
    @Test("Restarting the file in flight sends it again from the start")
    func restart() async {
        let attempts = Counter()
        let queue = FileDropQueue { url, progress in
            let attempt = attempts.next()
            if attempt == 1 {
                // First attempt waits for the restart, as a slow Wi-Fi push would.
                while progress(1, 10) { Thread.sleep(forTimeInterval: 0.01) }
                throw CancellationError()
            }
            _ = progress(10, 10)
            return "/sdcard/Download/\(url.lastPathComponent)"
        }
        var events: [FileDropQueue.Event] = []
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.onEvent = { event in
                events.append(event)
                if case .progress = event, attempts.value == 1 { queue.restartCurrent() }
                if event == .idle { done.resume() }
            }
            queue.enqueue([URL(fileURLWithPath: "/a.bin")])
        }
        #expect(attempts.value == 2)
        #expect(events.contains(.finished(fileName: "a.bin", remotePath: "/sdcard/Download/a.bin")))
        #expect(!events.contains { if case .failed = $0 { true } else { false } })
    }

    @Test("A failed file is tried once more, then reported")
    func retryOnce() async {
        let attempts = Counter()
        let queue = FileDropQueue { _, _ in
            _ = attempts.next()
            throw AdbSyncError.connectFailed("gone")
        }
        queue.retryDelay = 0
        var retries = 0
        queue.onRetry = { retries += 1 }
        var events: [FileDropQueue.Event] = []
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.onEvent = { event in
                events.append(event)
                if event == .idle { done.resume() }
            }
            queue.enqueue([URL(fileURLWithPath: "/a.bin")])
        }
        #expect(attempts.value == 2)
        #expect(retries == 1)
        #expect(events.contains { if case .failed(let name, _) = $0 { name == "a.bin" } else { false } })
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.withLock { count += 1; return count } }
    var value: Int { lock.withLock { count } }
}
