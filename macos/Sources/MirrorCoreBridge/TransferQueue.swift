import Foundation

/// Progress status of a file transfer item.
public enum TransferState: Sendable, Equatable {
    case queued
    case transferring(bytesTransferred: Int64, totalBytes: Int64, bytesPerSecond: Double)
    case completed
    case failed(String)
    case cancelled
}

/// Description of an active or queued file transfer.
public struct TransferItem: Sendable, Identifiable {
    public let id: UUID
    public let filename: String
    public let totalBytes: Int64
    public let transport: DeviceTransport
    public let isIncoming: Bool
    public var state: TransferState
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        filename: String,
        totalBytes: Int64,
        transport: DeviceTransport,
        isIncoming: Bool,
        state: TransferState = .queued,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.filename = filename
        self.totalBytes = totalBytes
        self.transport = transport
        self.isIncoming = isIncoming
        self.state = state
        self.createdAt = createdAt
    }

    public var progress: Double {
        switch state {
        case .queued:
            return 0.0
        case .transferring(let transferred, let total, _):
            return total > 0 ? min(1.0, Double(transferred) / Double(total)) : 0.0
        case .completed:
            return 1.0
        case .failed, .cancelled:
            return 0.0
        }
    }
}

/// Actor managing the active file transfer queue.
public actor TransferQueue {
    private var items: [UUID: TransferItem] = [:]

    public init() {}

    public func enqueue(item: TransferItem) {
        items[item.id] = item
    }

    public func updateProgress(id: UUID, transferred: Int64, bytesPerSecond: Double) {
        guard var item = items[id] else { return }
        item.state = .transferring(
            bytesTransferred: transferred,
            totalBytes: item.totalBytes,
            bytesPerSecond: bytesPerSecond
        )
        items[id] = item
    }

    public func markCompleted(id: UUID) {
        guard var item = items[id] else { return }
        item.state = .completed
        items[id] = item
    }

    public func markFailed(id: UUID, reason: String) {
        guard var item = items[id] else { return }
        item.state = .failed(reason)
        items[id] = item
    }

    public func cancel(id: UUID) {
        guard var item = items[id] else { return }
        item.state = .cancelled
        items[id] = item
    }

    public func activeTransfers() -> [TransferItem] {
        items.values.filter {
            switch $0.state {
            case .queued, .transferring:
                return true
            case .completed, .failed, .cancelled:
                return false
            }
        }
    }

    public func getItem(id: UUID) -> TransferItem? {
        items[id]
    }
}
