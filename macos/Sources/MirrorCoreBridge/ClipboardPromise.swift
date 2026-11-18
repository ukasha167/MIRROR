import Foundation

/// Types of clipboard content that can be synchronized.
public enum ClipboardContentType: String, Sendable, Codable, CaseIterable {
    case plainText
    case rtf
    case html
    case pngImage
    case jpegImage
    case fileURL
}

/// Metadata describing large clipboard payloads offered lazily.
public struct LazyClipboardMetadata: Sendable, Codable, Hashable {
    public let mimeType: String
    public let byteSize: Int64
    public let sha256: String
    public let previewThumbnail: Data?
    public let suggestedFilename: String?

    public init(
        mimeType: String,
        byteSize: Int64,
        sha256: String,
        previewThumbnail: Data? = nil,
        suggestedFilename: String? = nil
    ) {
        self.mimeType = mimeType
        self.byteSize = byteSize
        self.sha256 = sha256
        self.previewThumbnail = previewThumbnail
        self.suggestedFilename = suggestedFilename
    }
}

/// Complete or promised clipboard payload received from/sent to phone.
public struct ClipboardItem: Sendable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let contentTypes: [ClipboardContentType]
    public let inlineText: String?
    public let inlineData: Data?
    public let lazyMetadata: LazyClipboardMetadata?
    public let sourceDeviceId: String?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        contentTypes: [ClipboardContentType],
        inlineText: String? = nil,
        inlineData: Data? = nil,
        lazyMetadata: LazyClipboardMetadata? = nil,
        sourceDeviceId: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.contentTypes = contentTypes
        self.inlineText = inlineText
        self.inlineData = inlineData
        self.lazyMetadata = lazyMetadata
        self.sourceDeviceId = sourceDeviceId
    }

    /// Indicates whether full payload fetching is deferred until paste.
    public var isLazy: Bool {
        lazyMetadata != nil && inlineData == nil
    }
}
