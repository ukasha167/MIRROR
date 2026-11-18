import Foundation
import Testing
@testable import MirrorDesk
@testable import MirrorRenderer

/// Fixes from the 2026-11-19 Phase 3 hand test.

struct AudioDemuxerTests {
    static func packet(pts: UInt64, config: Bool = false, _ payload: [UInt8]) -> Data {
        var head = pts | (config ? 0x4000_0000_0000_0000 : 0)
        var out = Data()
        for _ in 0..<8 { out.insert(UInt8(head & 0xFF), at: 0); head >>= 8 }
        let size = UInt32(payload.count)
        out += Data([UInt8(size >> 24), UInt8(size >> 16 & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size & 0xFF)])
        return out + Data(payload)
    }

    @Test("Codec id, then PCM packets, split across reads; config packets skipped")
    func raw() throws {
        var demuxer = ScrcpyAudioDemuxer()
        let stream = Data([0x00, 0x72, 0x61, 0x77]) + Self.packet(pts: 0, config: true, [9])
            + Self.packet(pts: 1000, [1, 2, 3, 4]) + Self.packet(pts: 2000, [5, 6, 7, 8])
        var events: [ScrcpyAudioDemuxer.Event] = []
        for byte in stream { events += try demuxer.feed(Data([byte])) }
        #expect(events == [.codec(ScrcpyAudioDemuxer.rawCodecID), .pcm(Data([1, 2, 3, 4])), .pcm(Data([5, 6, 7, 8]))])
    }

    @Test("Codec 0 means the phone could not capture audio")
    func disabled() throws {
        var demuxer = ScrcpyAudioDemuxer()
        #expect(try demuxer.feed(Data([0, 0, 0, 0])) == [.disabled(error: false)])
        var failed = ScrcpyAudioDemuxer()
        #expect(try failed.feed(Data([0, 0, 0, 1])) == [.disabled(error: true)])
    }

    @Test("An oversized packet is an error, not a huge allocation")
    func oversized() {
        var demuxer = ScrcpyAudioDemuxer()
        let header = Data([0, 0x72, 0x61, 0x77, 0, 0, 0, 0, 0, 0, 0, 0, 0x7F, 0, 0, 0])
        #expect(throws: ScrcpyStreamError.self) { _ = try demuxer.feed(header) }
    }
}

struct PCMRingBufferTests {
    func pcm(frames: Int, value: Int16) -> Data {
        var samples = [Int16](repeating: value, count: frames * 2)
        return Data(bytes: &samples, count: samples.count * 2)
    }

    @Test("Silence until the start cushion fills, then samples as floats")
    func cushion() {
        let ring = PCMRingBuffer(startFrames: 4, maxFrames: 100)
        var left = [Float](repeating: 1, count: 4), right = left
        ring.write(pcm(frames: 2, value: 16_384))
        ring.read(count: 4, left: &left, right: &right)
        #expect(left == [0, 0, 0, 0])
        ring.write(pcm(frames: 2, value: 16_384))
        ring.read(count: 4, left: &left, right: &right)
        #expect(left == [0.5, 0.5, 0.5, 0.5] && right == left)
        #expect(ring.queuedFrames == 0)
    }

    @Test("Old samples are dropped past the cap, so lag stays bounded")
    func cap() {
        let ring = PCMRingBuffer(startFrames: 1, maxFrames: 10)
        ring.write(pcm(frames: 25, value: 1))
        #expect(ring.queuedFrames == 10)
    }
}

struct DeskTasksTests {
    static let dump = """
    Display #57 (activities from top to bottom):
      * Task{fa6983c #3318 type=standard A=10220:com.android.chrome U=0 visible=true sz=1}
        topResumedActivity=ActivityRecord{38586927 u0 com.android.chrome/org.chromium.chrome.browser.ChromeTabbedActivity t3318}
        * Hist  #0: ActivityRecord{38586927 u0 com.android.chrome/org.chromium.chrome.browser.ChromeTabbedActivity t3318}
      * Task{d8c631e #3316 type=standard A=10160:affinity.name U=0 visible=false sz=1}
        mLastPausedActivity: ActivityRecord{142953305 u0 com.google.android.deskclock/com.android.deskclock.DeskClock t3316}
      * Task{a87e2df #3314 type=home U=0 visible=false sz=1}
        * Task{a75bb2c #3315 type=home A=10247:com.google.android.apps.nexuslauncher nonResizable U=0}
          * Hist  #0: ActivityRecord{108911998 u0 com.google.android.apps.nexuslauncher/com.android.launcher3.secondarydisplay.SecondaryDisplayLauncher t3315}
    Display #0 (activities from top to bottom):
      * Task{909703f #3313 type=standard A=10312:com.whatsapp.w4b U=0 visible=true sz=2}
        * Hist  #1: ActivityRecord{181942588 u0 com.whatsapp.w4b/com.whatsapp.Conversation t3313}
    """

    @Test("App tasks on the desk display, front first, with packages from their activities")
    func parse() {
        #expect(DeskTasks.parse(Self.dump, displayId: 57) == [
            DeskTask(id: 3318, package: "com.android.chrome"),
            DeskTask(id: 3316, package: "com.google.android.deskclock"),
        ])
        #expect(DeskTasks.parse(Self.dump, displayId: 5).isEmpty)
    }

    @Test("Desk mode has a Recents button again")
    func buttons() {
        #expect(NavigationButtons.Button.forMode(desk: true) == [.back, .home, .recents, .apps])
    }
}

struct SoloAppConfigTests {
    @Test("A solo app display has no Android bars and no audio; desk keeps both")
    func solo() {
        let solo = NativeMirrorConfig(mode: .defaultDesk, serverPath: "/s", soloApp: true)
        #expect(solo.serverArguments.contains("vd_system_decorations=false"))
        #expect(!solo.streamOptions.audio)
        let desk = NativeMirrorConfig(mode: .defaultDesk, serverPath: "/s")
        #expect(!desk.serverArguments.contains("vd_system_decorations=false"))
        #expect(desk.serverArguments.contains("display_ime_policy=local"))
        #expect(desk.streamOptions.audio)
    }
}

@MainActor
struct TransferMenuTests {
    @Test("The badge keeps one width from 0 to 100 percent")
    func badge() {
        let widths = [0.0, 0.04, 0.42, 1.0].map { DeskController.percent($0).count }
        #expect(Set(widths) == [4])
        #expect(DeskController.percent(0.04) == "\u{2007}\u{2007}4%")
    }

    @Test("Long names are cut in the middle and keep the extension")
    func shortName() {
        let name = "Through.The.Olive.Trees.1994.1080p.BluRay.x264-[YTS.LT].mp4"
        let short = DeskController.short(name)
        #expect(short.count == 32)
        #expect(short.hasSuffix("[YTS.LT].mp4"))
        #expect(DeskController.short("photo.jpg") == "photo.jpg")
    }
}

/// Returns scripted replies and keeps only the request text it was sent (not file bytes).
final class ShellScriptStream: AdbByteStream {
    var replies: Data
    var requests = ""
    init(_ replies: String) { self.replies = Data(replies.utf8) }
    func write(_ data: Data) throws {
        if data.count < 512 { requests += String(decoding: data, as: UTF8.self) }
    }
    func read(_ count: Int) throws -> Data {
        let out = replies.prefix(count)
        replies = replies.dropFirst(out.count)
        return Data(out)
    }
    func close() {}
}

struct ResumablePushTests {
    @Test("A push resumes after the last whole segment on the phone and splices the rest")
    func resume() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("resume-\(UUID().uuidString).bin")
        let size = AdbResumablePush.segment * 2 + 1_000
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(size))
        try handle.close()
        defer { try? FileManager.default.removeItem(at: file) }

        let sync = "OKAYOKAYOKAY\0\0\0\0"
        // stat (one segment plus a cut-short splice), segment, splice, segment, splice, rename.
        let streams = [ShellScriptStream("OKAYOKAY\(AdbResumablePush.segment + 5)\n"),
                       ShellScriptStream(sync), ShellScriptStream("OKAYOKAYrc=0\n"),
                       ShellScriptStream(sync), ShellScriptStream("OKAYOKAYrc=0\n"),
                       ShellScriptStream("OKAYOKAYrc=0\n")]
        var next = 0
        let push = AdbResumablePush(sync: AdbSyncPush(serial: "S", connect: {
            defer { next += 1 }
            return streams[next]
        }))
        var first: Int64?
        let remote = try push.push(file) { sent, total in
            if first == nil { first = sent }
            #expect(total == size)
            return true
        }
        #expect(first == AdbResumablePush.segment)
        #expect(next == 6)
        #expect(remote == "/sdcard/Download/\(file.lastPathComponent)")
        #expect(streams[2].requests.contains("seek=32 "))
        #expect(streams[4].requests.contains("seek=64 "))
        #expect(streams[5].requests.contains("mv -f"))
    }

    @Test("Phone paths are single-quoted, quotes inside included")
    func quote() {
        #expect(AdbResumablePush.quote("/sdcard/Download/it's.mp4") == #"'/sdcard/Download/it'\''s.mp4'"#)
    }
}

@MainActor
struct FileDropStopTests {
    @Test("Stop reports at once, aborts the socket, and discards the partial copy")
    func stop() async {
        let queue = FileDropQueue { _, progress in
            while progress(1, 10) { Thread.sleep(forTimeInterval: 0.01) }
            throw CancellationError()
        }
        var aborted = 0
        var discarded: [URL] = []
        queue.onAbort = { aborted += 1 }
        var events: [FileDropQueue.Event] = []
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.onDiscard = { discarded.append($0) }
            queue.onEvent = { event in
                events.append(event)
                if case .progress = event, !events.contains(.stopped(fileName: "a.bin")) {
                    queue.cancelAll()
                    #expect(events.last == .stopped(fileName: "a.bin"))
                }
                if event == .idle { done.resume() }
            }
            queue.enqueue([URL(fileURLWithPath: "/a.bin")])
        }
        #expect(aborted == 1)
        #expect(discarded == [URL(fileURLWithPath: "/a.bin")])
        #expect(!events.contains { if case .failed = $0 { true } else { false } })
    }
}
