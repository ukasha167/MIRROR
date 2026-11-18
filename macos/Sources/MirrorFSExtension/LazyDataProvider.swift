import Foundation

#if canImport(AppKit)
import AppKit

/// Protocol for lazy clipboard fetchers.
public protocol LazyClipboardFetcher: AnyObject, Sendable {
    func fetchPayload(for metadata: String, type: String) async throws -> Data
}

/// Lazy data provider for NSPasteboard items to avoid transferring large payloads until paste.
public final class LazyDataProvider: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
    public let metadataIdentifier: String
    public weak var fetcher: LazyClipboardFetcher?
    private var cachedData: [String: Data] = [:]
    private let lock = NSLock()

    public init(metadataIdentifier: String, fetcher: LazyClipboardFetcher? = nil) {
        self.metadataIdentifier = metadataIdentifier
        self.fetcher = fetcher
        super.init()
    }

    /// Sets pre-cached payload data if available.
    public func setPreloadedData(_ data: Data, forType type: NSPasteboard.PasteboardType) {
        lock.lock()
        defer { lock.unlock() }
        cachedData[type.rawValue] = data
    }

    // MARK: - NSPasteboardItemDataProvider

    public func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        lock.lock()
        if let existing = cachedData[type.rawValue] {
            lock.unlock()
            item.setData(existing, forType: type)
            return
        }
        lock.unlock()

        // Fetch synchronously on pasteboard queue or fallback to placeholder
        if let fetcher = self.fetcher {
            final class FetchResultBox: @unchecked Sendable {
                var data: Data?
            }
            let box = FetchResultBox()
            let semaphore = DispatchSemaphore(value: 0)
            let metaId = self.metadataIdentifier
            let typeStr = type.rawValue

            Task {
                box.data = try? await fetcher.fetchPayload(for: metaId, type: typeStr)
                semaphore.signal()
            }

            _ = semaphore.wait(timeout: .now() + 2.0)

            if let result = box.data {
                lock.lock()
                cachedData[type.rawValue] = result
                lock.unlock()
                item.setData(result, forType: type)
                return
            }
        }

        // Empty placeholder fallback
        item.setData(Data(), forType: type)
    }
}
#endif
