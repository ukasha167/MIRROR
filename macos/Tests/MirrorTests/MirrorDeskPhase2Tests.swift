import Foundation
import CoreGraphics
import Testing
@testable import MirrorDesk
import MirrorRenderer

struct TrackpadScrollTests {
    let screen = CGSize(width: 1000, height: 2000)

    @Test("A trackpad scroll becomes press, drag, lift so Android can fling")
    func dragLifecycle() {
        var t = TrackpadScrollTranslator(screen: screen)
        let at = CGPoint(x: 500, y: 1000)
        #expect(t.handle(phase: .began, location: at, delta: .zero, wheelDelta: .zero) == [.touch(.down, at)])
        #expect(t.handle(phase: .changed, location: at, delta: CGVector(dx: 0, dy: 40), wheelDelta: .zero)
                == [.touch(.move, CGPoint(x: 500, y: 1040))])
        #expect(t.handle(phase: .ended, location: at, delta: .zero, wheelDelta: .zero)
                == [.touch(.up, CGPoint(x: 500, y: 1040))])
        #expect(!t.isDragging)
    }

    @Test("macOS momentum events are dropped")
    func momentumDropped() {
        var t = TrackpadScrollTranslator(screen: screen)
        #expect(t.handle(phase: .momentum, location: .zero, delta: CGVector(dx: 0, dy: 30), wheelDelta: .zero).isEmpty)
    }

    @Test("A mouse wheel still sends wheel events")
    func wheel() {
        var t = TrackpadScrollTranslator(screen: screen)
        let out = t.handle(phase: .none, location: CGPoint(x: 10, y: 10), delta: .zero, wheelDelta: CGVector(dx: 0, dy: -1))
        #expect(out == [.wheel(dx: 0, dy: -1, at: CGPoint(x: 10, y: 10))])
    }

    @Test("At the screen edge the drag lifts and presses again at its first point")
    func edgeRestart() {
        var t = TrackpadScrollTranslator(screen: screen)
        let at = CGPoint(x: 500, y: 1900)
        _ = t.handle(phase: .began, location: at, delta: .zero, wheelDelta: .zero)
        let out = t.handle(phase: .changed, location: at, delta: CGVector(dx: 0, dy: 200), wheelDelta: .zero)
        let edge = CGPoint(x: 500, y: 2000 - TrackpadScrollTranslator.edgeMargin)
        #expect(out == [.touch(.move, edge), .touch(.up, edge), .touch(.down, at)])
        #expect(t.handle(phase: .changed, location: at, delta: CGVector(dx: 0, dy: 10), wheelDelta: .zero)
                == [.touch(.move, CGPoint(x: 500, y: 1910))])
    }

    @Test("A changed event without began starts a drag")
    func lateStart() {
        var t = TrackpadScrollTranslator(screen: screen)
        let at = CGPoint(x: 100, y: 100)
        #expect(t.handle(phase: .changed, location: at, delta: CGVector(dx: 0, dy: 5), wheelDelta: .zero) == [.touch(.down, at)])
    }
}

struct AdbSyncWireTests {
    @Test("Host requests carry a 4-digit hex length")
    func hostRequest() {
        #expect(AdbSyncWire.hostRequest("host:version") == Data("000chost:version".utf8))
    }

    @Test("SEND carries path and regular-file mode, length little-endian")
    func send() {
        let spec = "/sdcard/Download/a.txt,33188"  // 0o100644
        let data = AdbSyncWire.send(remotePath: "/sdcard/Download/a.txt")
        #expect(data.prefix(4) == Data("SEND".utf8))
        #expect(AdbSyncWire.readU32LE(data.dropFirst(4)) == UInt32(spec.utf8.count))
        #expect(data.dropFirst(8) == Data(spec.utf8))
    }

    @Test("DONE carries the mtime")
    func done() {
        #expect(AdbSyncWire.done(mtime: 0x01020304) == Data("DONE".utf8) + Data([4, 3, 2, 1]))
    }
}

/// In-memory adb server: replies from a script, records what was written.
final class ScriptedStream: AdbByteStream {
    var replies: Data
    var written = Data()
    init(replies: Data) { self.replies = replies }
    func write(_ data: Data) throws { written += data }
    func read(_ count: Int) throws -> Data {
        let out = replies.prefix(count)
        replies = replies.dropFirst(out.count)
        return Data(out)
    }
    func close() {}
}

struct AdbSyncPushTests {
    func tempFile(bytes: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("push-\(UUID().uuidString).bin")
        try Data(repeating: 7, count: bytes).write(to: url)
        return url
    }

    @Test("Push sends the file in 64 KiB chunks and reports every byte")
    func pushChunks() throws {
        let file = try tempFile(bytes: 150_000)
        defer { try? FileManager.default.removeItem(at: file) }
        let stream = ScriptedStream(replies: Data("OKAYOKAY".utf8) + Data("OKAY".utf8) + Data([0, 0, 0, 0]))
        var reports: [Int64] = []
        let remote = try AdbSyncPush(serial: "SER1", connect: { stream }).push(file) { sent, total in
            #expect(total == 150_000)
            reports.append(sent)
            return true
        }
        #expect(remote == "/sdcard/Download/\(file.lastPathComponent)")
        #expect(reports == [65_536, 131_072, 150_000])
        #expect(stream.written.starts(with: AdbSyncWire.hostRequest("host:transport:SER1")))
    }

    @Test("A FAIL from the phone surfaces its message")
    func pushFail() throws {
        let file = try tempFile(bytes: 10)
        defer { try? FileManager.default.removeItem(at: file) }
        let msg = "no space"
        let stream = ScriptedStream(replies: Data("OKAYOKAYFAIL".utf8) + Data([UInt8(msg.count), 0, 0, 0]) + Data(msg.utf8))
        #expect(throws: AdbSyncError.syncFailed(message: msg)) {
            try AdbSyncPush(serial: "S", connect: { stream }).push(file) { _, _ in true }
        }
    }

    @Test("A refused transport reports adb's reason")
    func hostFail() throws {
        let file = try tempFile(bytes: 10)
        defer { try? FileManager.default.removeItem(at: file) }
        let stream = ScriptedStream(replies: Data("FAIL0010device not found".utf8))
        #expect(throws: AdbSyncError.hostRefused(service: "host:transport:S", message: "device not found")) {
            try AdbSyncPush(serial: "S", connect: { stream }).push(file) { _, _ in true }
        }
    }

    @Test("Returning false from progress cancels")
    func cancel() throws {
        let file = try tempFile(bytes: 200_000)
        defer { try? FileManager.default.removeItem(at: file) }
        let stream = ScriptedStream(replies: Data("OKAYOKAY".utf8))
        #expect(throws: CancellationError.self) {
            try AdbSyncPush(serial: "S", connect: { stream }).push(file) { _, _ in false }
        }
    }
}

struct PowerKeyWatcherTests {
    @Test("Only power key DOWN lines count")
    func parse() {
        #expect(PowerKeyWatcher.isPowerDown("/dev/input/event2: EV_KEY       KEY_POWER            DOWN"))
        #expect(!PowerKeyWatcher.isPowerDown("/dev/input/event2: EV_KEY       KEY_POWER            UP"))
        #expect(!PowerKeyWatcher.isPowerDown("/dev/input/event3: EV_KEY       KEY_VOLUMEDOWN       DOWN"))
        #expect(!PowerKeyWatcher.isPowerDown(""))
    }
}

@MainActor
struct FileDropQueueTests {
    @Test("Files go one at a time and the queue reports idle at the end")
    func sequential() async {
        let queue = FileDropQueue { url, progress in
            _ = progress(10, 10)
            return "/sdcard/Download/\(url.lastPathComponent)"
        }
        var events: [FileDropQueue.Event] = []
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.onEvent = { event in
                events.append(event)
                if event == .idle { done.resume() }
            }
            queue.enqueue([URL(fileURLWithPath: "/a.txt"), URL(fileURLWithPath: "/b.txt")])
        }
        let finished = events.compactMap { if case .finished(let name, _) = $0 { name } else { nil } }
        #expect(finished == ["a.txt", "b.txt"])
        #expect(events.last == .idle)
    }
}

struct PhoneAppsTests {
    @Test("App list keeps names with spaces and marks system apps")
    func parse() {
        let out = """
        [server] INFO: List of apps:
         * Android System Angle           com.android.angle
         - WhatsApp Business              com.whatsapp.w4b
         * Calculator                     com.google.android.calculator
        """
        let apps = PhoneApps.parse(out)
        #expect(apps.map(\.name) == ["Android System Angle", "Calculator", "WhatsApp Business"])
        #expect(apps.first { $0.package == "com.whatsapp.w4b" }?.isSystem == false)
        #expect(apps.first { $0.package == "com.android.angle" }?.isSystem == true)
    }

    @Test("Virtual display id comes from the server's New display line")
    func displayID() {
        #expect(PhoneApps.virtualDisplayID(inServerLog: "[server] INFO: New display: 1600x1000/200 (id=27)\n") == 27)
        #expect(PhoneApps.virtualDisplayID(inServerLog: "[server] INFO: New display: 1600x1000/2") == nil)
    }

    @Test("Home starts the secondary home intent on the virtual display")
    func home() {
        let args = PhoneApps.homeArguments(serial: "S", displayId: 27)
        #expect(args.contains("--display") && args.contains("27"))
        #expect(args.last == "android.intent.category.SECONDARY_HOME")
    }

    @Test("Recent apps keep the newest first, no repeats, at most 8")
    func recent() {
        let defaults = UserDefaults(suiteName: "RecentAppsTest-\(UUID())")!
        let recent = RecentApps(defaults: defaults)
        for i in 0..<10 { recent.record("app\(i)") }
        recent.record("app5")
        #expect(recent.packages.first == "app5")
        #expect(recent.packages.count == RecentApps.limit)
        #expect(Set(recent.packages).count == recent.packages.count)
    }

    @Test("Desk mode shows Back, Home, Apps; panel-off shows the four Android keys")
    func buttons() {
        #expect(NavigationButtons.Button.forMode(desk: true) == [.back, .home, .recents, .apps])
        #expect(NavigationButtons.Button.forMode(desk: false) == [.back, .home, .recents, .notifications])
    }
}

struct QuickShareSummaryTests {
    @Test("Summary names one file, counts several, prefers shared text")
    func summary() {
        #expect(QuickShareReceiver.summary(files: ["a.jpg"], text: nil) == "a.jpg")
        #expect(QuickShareReceiver.summary(files: ["a", "b", "c"], text: nil) == "3 files")
        #expect(QuickShareReceiver.summary(files: [], text: "https://example.com") == "https://example.com")
    }
}
