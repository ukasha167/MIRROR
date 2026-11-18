import Foundation

/// Frame types exchanged over the Quick Share offline TCP connection.
public enum QuickShareFrameType: UInt8, Sendable, Codable {
    case connectionRequest = 1
    case connectionResponse = 2
    case payloadTransfer = 3
    case keepAlive = 4
    case disconnect = 5
}

/// Description of a file offered over Quick Share.
public struct QuickShareFile: Sendable, Codable, Equatable {
    public let payloadId: Int64
    public let filename: String
    public let size: Int64
    public let mimeType: String

    public init(payloadId: Int64, filename: String, size: Int64, mimeType: String) {
        self.payloadId = payloadId
        self.filename = filename
        self.size = size
        self.mimeType = mimeType
    }
}

/// Metadata payload for a connection request frame.
public struct ConnectionRequestPayload: Sendable, Codable {
    public let senderDeviceName: String
    public let files: [QuickShareFile]

    public init(senderDeviceName: String, files: [QuickShareFile]) {
        self.senderDeviceName = senderDeviceName
        self.files = files
    }
}

/// Response status to an incoming transfer request.
public enum ConnectionResponseStatus: UInt8, Sendable, Codable {
    case accept = 1
    case reject = 2
    case notEnoughSpace = 3
}
