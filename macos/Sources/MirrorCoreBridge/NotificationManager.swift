import Foundation

/// Action that can be executed on a remote notification.
public struct NotificationAction: Sendable, Identifiable, Hashable {
    public let id: String
    public let title: String
    public let isReplyInput: Bool

    public init(id: String, title: String, isReplyInput: Bool = false) {
        self.id = id
        self.title = title
        self.isReplyInput = isReplyInput
    }
}

/// Incoming notification mirrored from Android device.
public struct ContinuityNotification: Sendable, Identifiable {
    public let id: String
    public let appPackage: String
    public let appName: String
    public let title: String
    public let body: String
    public let iconData: Data?
    public let timestamp: Date
    public let replyActionKey: String?
    public let actions: [NotificationAction]
    public let category: String?

    public init(
        id: String,
        appPackage: String,
        appName: String,
        title: String,
        body: String,
        iconData: Data? = nil,
        timestamp: Date = Date(),
        replyActionKey: String? = nil,
        actions: [NotificationAction] = [],
        category: String? = nil
    ) {
        self.id = id
        self.appPackage = appPackage
        self.appName = appName
        self.title = title
        self.body = body
        self.iconData = iconData
        self.timestamp = timestamp
        self.replyActionKey = replyActionKey
        self.actions = actions
        self.category = category
    }
}
