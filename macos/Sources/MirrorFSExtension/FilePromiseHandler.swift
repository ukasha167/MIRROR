import Foundation

#if canImport(AppKit)
import AppKit
import UniformTypeIdentifiers

/// Delegate receiving requests to pull file bytes when Finder destination drops.
public protocol FilePromisePullDelegate: AnyObject, Sendable {
    func pullRemoteFile(remoteUri: String, destinationURL: URL) async throws
}

private final class SendableCompletionBox: @unchecked Sendable {
    let handler: (Error?) -> Void
    init(_ handler: @escaping (Error?) -> Void) {
        self.handler = handler
    }
}

/// Handler for dragging files out of mirrored screen into macOS Finder or Desktop.
public final class FilePromiseHandler: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {
    public let filename: String
    public let remoteUri: String
    public weak var pullDelegate: FilePromisePullDelegate?
    private let workQueue = OperationQueue()

    public init(filename: String, remoteUri: String, pullDelegate: FilePromisePullDelegate? = nil) {
        self.filename = filename
        self.remoteUri = remoteUri
        self.pullDelegate = pullDelegate
        super.init()
        self.workQueue.qualityOfService = .userInitiated
    }

    /// Creates an NSFilePromiseProvider configured for this drag session.
    public func makePromiseProvider() -> NSFilePromiseProvider {
        let ext = (filename as NSString).pathExtension
        let utType = UTType(filenameExtension: ext) ?? .data
        let provider = NSFilePromiseProvider(fileType: utType.identifier, delegate: self)
        provider.userInfo = [
            "filename": filename,
            "remoteUri": remoteUri
        ]
        return provider
    }

    // MARK: - NSFilePromiseProviderDelegate

    public func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType type: String) -> String {
        filename
    }

    public func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let box = SendableCompletionBox(completionHandler)
        let uri = self.remoteUri
        let delegate = self.pullDelegate

        workQueue.addOperation {
            Task {
                do {
                    if let pullDelegate = delegate {
                        try await pullDelegate.pullRemoteFile(remoteUri: uri, destinationURL: url)
                    } else {
                        // Default mock creation for testing/preview
                        try Data("Sample file content".utf8).write(to: url)
                    }
                    box.handler(nil)
                } catch {
                    box.handler(error)
                }
            }
        }
    }
}
#endif
