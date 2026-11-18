import Foundation

/// Sends a large file in segments so a push that stops (cable plugged in or pulled, Wi-Fi
/// drop) continues where it stopped on the new transport instead of starting again.
///
/// adb's sync protocol cannot write at an offset, and adbd deletes a file whose SEND did not
/// finish. So each segment goes to its own file over sync (33 MB/s over USB here; streaming
/// into `dd` through `exec:` managed 12 MB/s), then one shell command copies it into the
/// partial file at its offset and deletes it:
///
///     dd if=<segment> of=<partial> bs=1048576 seek=<MiB offset> conv=notrunc && rm <segment>
///
/// The partial file's size says how much is done. Positional writes make a late write from a
/// dead transport harmless: it writes the same bytes at the same place. When the partial file
/// is complete it is renamed to the real name.
public struct AdbResumablePush {
    /// 32 MiB: at most about 10 s of Wi-Fi to repeat after a switch, and one shell command
    /// (about 0.1 s) per second of USB transfer.
    public static let segment: Int64 = 32 << 20

    let sync: AdbSyncPush

    public init(sync: AdbSyncPush) { self.sync = sync }

    /// Hidden name for the unfinished copy. Size and modification time are in the name so a
    /// different file with the same name never resumes from this one's bytes.
    public static func partialPath(for file: URL, remoteDir: String = AdbSyncPush.downloadDir) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: file.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = Int(((attrs?[.modificationDate] as? Date) ?? .distantPast).timeIntervalSince1970)
        return "\(remoteDir)/.\(file.lastPathComponent).\(size)-\(mtime).mirror-part"
    }

    /// Sends `file` into `remoteDir` and returns the remote path. `progress` gets bytes done
    /// in the whole file, starting at the resumed offset; return false to stop (the partial file
    /// stays, so the next push resumes from it).
    @discardableResult
    public func push(_ file: URL, to remoteDir: String = AdbSyncPush.downloadDir,
                     progress: AdbSyncPush.Progress) throws -> String {
        let total = try AdbSyncPush.fileSize(file)
        let remote = "\(remoteDir)/\(file.lastPathComponent)"
        // One segment or less: a plain push is as cheap to repeat as a segment.
        guard total > Self.segment else {
            try sync.push(file, range: 0..<total, to: remote) { progress($0, total) }
            return remote
        }
        let partial = Self.partialPath(for: file, remoteDir: remoteDir)
        var done = try doneBytes(partial, total: total)
        guard progress(done, total) else { throw CancellationError() }
        let nonce = String(UInt32.random(in: 0...UInt32.max), radix: 16)
        while done < total {
            let end = min(done + Self.segment, total)
            // A fresh name per attempt: adbd on a dead transport deletes its own unfinished
            // segment, and must not delete the one this transport is writing.
            let piece = "\(partial).\(done >> 20)-\(nonce)"
            try sync.push(file, range: done..<end, to: piece) { progress(done + $0, total) }
            try run("dd if=\(Self.quote(piece)) of=\(Self.quote(partial)) bs=1048576 seek=\(done >> 20) "
                    + "conv=notrunc status=none && rm -f \(Self.quote(piece))", context: "splice segment")
            done = end
        }
        // Also clears segments a dead transport left behind.
        try run("mv -f \(Self.quote(partial)) \(Self.quote(remote)) && rm -f \(Self.quote(partial)).*",
                context: "rename finished file")
        return remote
    }

    /// Deletes the unfinished copy of `file` after the user stops the transfer.
    public func discard(_ file: URL, remoteDir: String = AdbSyncPush.downloadDir) {
        let partial = Self.partialPath(for: file, remoteDir: remoteDir)
        _ = try? sync.shell("rm -f \(Self.quote(partial)) \(Self.quote(partial)).*")
    }

    /// Whole segments already in the partial file. A splice cut short leaves a size between
    /// segment boundaries; that segment is sent again.
    func doneBytes(_ partial: String, total: Int64) throws -> Int64 {
        let out = try sync.shell("stat -c %s \(Self.quote(partial)) 2>/dev/null || echo 0")
        let size = Int64(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        return min(size / Self.segment * Self.segment, total)
    }

    private func run(_ command: String, context: String) throws {
        let out = try sync.shell("\(command); echo rc=$?")
        guard out.contains("rc=0") else {
            throw AdbSyncError.syncFailed(message: "\(context): \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    /// Single-quotes `path` for the phone's shell.
    static func quote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
