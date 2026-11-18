import Foundation

/// State of the Quick Share file receiving process.
public enum ReceiverState: Sendable, Equatable {
    case waitingForConnection
    case handshaking
    case awaitingConsent(sender: String, files: [QuickShareFile], pin: String)
    case receiving(sender: String, files: [QuickShareFile], bytesReceived: Int64, totalBytes: Int64)
    case completed(files: [QuickShareFile])
    case failed(reason: String)
}

/// State machine driving the end-to-end Quick Share receiver session.
public final class ReceiverStateMachine: @unchecked Sendable {
    public private(set) var state: ReceiverState = .waitingForConnection
    public let ukey2Session: UKEY2Session
    public var autoAcceptPairedDevices: Bool = true
    public var pairedFingerprints: Set<String> = []

    private var activeFiles: [QuickShareFile] = []
    private var totalBytesToReceive: Int64 = 0
    private var bytesReceived: Int64 = 0
    private var currentSender: String = "Android Device"

    public init(ukey2Session: UKEY2Session = UKEY2Session()) {
        self.ukey2Session = ukey2Session
    }

    /// Handles incoming client UKEY2 ClientInit packet.
    public func handleClientInit(data: Data) throws -> Data {
        state = .handshaking
        return try ukey2Session.processClientInit(payload: data)
    }

    /// Handles incoming client UKEY2 ClientFinish packet.
    public func handleClientFinish(data: Data) throws -> (authPin: String, sessionKey: Data) {
        return try ukey2Session.processClientFinish(payload: data)
    }

    /// Handles incoming connection request with files metadata.
    public func handleConnectionRequest(sender: String, files: [QuickShareFile], pin: String, senderFingerprint: String? = nil) -> ConnectionResponseStatus {
        self.currentSender = sender
        self.activeFiles = files
        self.totalBytesToReceive = files.reduce(0) { $0 + $1.size }
        self.bytesReceived = 0

        // Auto-accept if device is paired and pinned
        if autoAcceptPairedDevices, let fp = senderFingerprint, pairedFingerprints.contains(fp) {
            state = .receiving(sender: sender, files: files, bytesReceived: 0, totalBytes: totalBytesToReceive)
            return .accept
        }

        state = .awaitingConsent(sender: sender, files: files, pin: pin)
        return .accept // Defaults to accepting for mock or after user confirmation
    }

    /// User accepts or auto-accept initiates receiving state.
    public func acceptTransfer() {
        guard case .awaitingConsent(let sender, let files, _) = state else { return }
        state = .receiving(sender: sender, files: files, bytesReceived: bytesReceived, totalBytes: totalBytesToReceive)
    }

    /// User rejects transfer.
    public func rejectTransfer() {
        state = .failed(reason: "Transfer rejected by user")
    }

    /// Progresses file payload receipt.
    public func handlePayloadChunk(chunkSize: Int64) {
        guard case .receiving(let sender, let files, _, let total) = state else { return }
        bytesReceived += chunkSize

        if bytesReceived >= total {
            state = .completed(files: files)
        } else {
            state = .receiving(sender: sender, files: files, bytesReceived: bytesReceived, totalBytes: total)
        }
    }

    /// Resets state machine back to waiting.
    public func reset() {
        state = .waitingForConnection
        activeFiles.removeAll()
        totalBytesToReceive = 0
        bytesReceived = 0
    }
}
