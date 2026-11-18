import Foundation

/// Sends dropped files to the phone one at a time and reports progress for the window's
/// transfer bar.
@MainActor
public final class FileDropQueue {
    public struct Status: Equatable, Sendable {
        public var fileName: String
        public var sent: Int64
        public var total: Int64
        /// Files still waiting after this one.
        public var queued: Int

        public var fraction: Double { total > 0 ? Double(sent) / Double(total) : 1 }
    }

    public enum Event: Equatable, Sendable {
        case progress(Status)
        case finished(fileName: String, remotePath: String)
        case failed(fileName: String, message: String)
        case idle
    }

    public var onEvent: ((Event) -> Void)?

    private let push: @Sendable (URL, @escaping AdbSyncPush.Progress) throws -> String
    private var pending: [URL] = []
    private var running = false
    private var cancel = CancelFlag()
    /// Id of the file in flight. Progress tasks for an older file are dropped, since one can
    /// reach the main actor after that file's `finished` event.
    private var currentID = 0

    public convenience init(serial: String) {
        self.init { url, progress in try AdbSyncPush(serial: serial).push(url, progress: progress) }
    }

    /// `push` runs off the main thread; tests pass a fake.
    public init(push: @escaping @Sendable (URL, @escaping AdbSyncPush.Progress) throws -> String) {
        self.push = push
    }

    public func enqueue(_ urls: [URL]) {
        pending += urls
        if !running { next() }
    }

    /// Stops the current file (adbd drops the partial copy) and clears the queue.
    public func cancelAll() {
        pending.removeAll()
        cancel.set()
    }

    private func next() {
        guard !pending.isEmpty else {
            running = false
            onEvent?(.idle)
            return
        }
        running = true
        let url = pending.removeFirst()
        let name = url.lastPathComponent
        let queued = pending.count
        let push = self.push
        cancel = CancelFlag()
        let cancel = self.cancel
        currentID += 1
        let id = currentID
        // Progress fires per 64 KiB chunk; forward about 20 updates a second at most.
        let throttle = ProgressThrottle(interval: 0.05)

        Task.detached { [weak self] in
            let result = Result {
                try push(url) { sent, total in
                    if throttle.shouldFire(done: sent >= total) {
                        Task { @MainActor in
                            guard self?.currentID == id else { return }
                            self?.onEvent?(.progress(Status(fileName: name, sent: sent, total: total, queued: queued)))
                        }
                    }
                    return !cancel.isSet
                }
            }
            await MainActor.run {
                guard let self else { return }
                self.currentID += 1
                switch result {
                case .success(let remote): self.onEvent?(.finished(fileName: name, remotePath: remote))
                case .failure(is CancellationError): break
                case .failure(let error): self.onEvent?(.failed(fileName: name, message: "\(error)"))
                }
                self.next()
            }
        }
    }
}

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

/// Lets through one progress update per `interval` seconds, plus the final one.
final class ProgressThrottle: @unchecked Sendable {
    private let interval: TimeInterval
    private var last = Date.distantPast
    private let lock = NSLock()

    init(interval: TimeInterval) { self.interval = interval }

    func shouldFire(done: Bool) -> Bool {
        lock.withLock {
            let now = Date()
            guard done || now.timeIntervalSince(last) >= interval else { return false }
            last = now
            return true
        }
    }
}
