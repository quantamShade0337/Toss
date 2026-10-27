import Foundation

public enum ContentKind: String, Codable, CaseIterable, Sendable, Hashable {
    case text, link, image, file, location, phone, email, event, code

    public var symbol: String {
        switch self {
        case .text: "text.alignleft"
        case .link: "link"
        case .image: "photo"
        case .file: "doc"
        case .location: "map"
        case .phone: "phone"
        case .email: "envelope"
        case .event: "calendar"
        case .code: "chevron.left.forwardslash.chevron.right"
        }
    }
}

public enum TransferStatus: String, Codable, Sendable, Hashable {
    case queued, discovering, sending, sent, waitingForDevice, delivered, failed, cancelled

    public func canTransition(to next: Self) -> Bool {
        switch (self, next) {
        case (.queued, .discovering), (.queued, .sending), (.queued, .waitingForDevice), (.queued, .cancelled), (.queued, .failed), (.queued, .delivered),
             (.discovering, .sending), (.discovering, .queued), (.discovering, .failed),
             (.sending, .delivered), (.sending, .sent), (.sending, .waitingForDevice), (.sending, .queued), (.sending, .failed),
             (.sent, .sending), (.sent, .waitingForDevice), (.sent, .delivered), (.sent, .queued), (.sent, .failed),
             (.waitingForDevice, .delivered), (.waitingForDevice, .queued), (.waitingForDevice, .failed),
             (.failed, .delivered), (.failed, .queued): true
        default: false
        }
    }
}

public struct TransferItem: Codable, Identifiable, Sendable, Hashable {
    public var id: UUID
    public var createdAt: Date
    public var senderDeviceID: String
    public var receiverDeviceID: String
    public var kind: ContentKind
    public var title: String
    public var subtitle: String
    public var text: String?
    public var sourceURL: URL?
    public var filename: String?
    public var typeIdentifier: String?
    public var byteCount: Int
    public var status: TransferStatus
    public var scheduledAt: Date?
    public var completedAt: Date?
    public var directAttemptedAt: Date?
    public var failure: DeliveryIssue?
    public var isRead: Bool
    public var isArchived: Bool
    public var blobID: UUID?

    public init(id: UUID = UUID(), createdAt: Date = .now, senderDeviceID: String,
                receiverDeviceID: String, kind: ContentKind, title: String, subtitle: String = "",
                text: String? = nil, sourceURL: URL? = nil, filename: String? = nil,
                typeIdentifier: String? = nil, byteCount: Int = 0, status: TransferStatus = .queued,
                scheduledAt: Date? = nil, completedAt: Date? = nil, isRead: Bool = false,
                isArchived: Bool = false, blobID: UUID? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.senderDeviceID = senderDeviceID
        self.receiverDeviceID = receiverDeviceID
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.text = text
        self.sourceURL = sourceURL
        self.filename = filename
        self.typeIdentifier = typeIdentifier
        self.byteCount = byteCount
        self.status = status
        self.scheduledAt = scheduledAt
        self.completedAt = completedAt
        self.directAttemptedAt = nil
        self.failure = nil
        self.isRead = isRead
        self.isArchived = isArchived
        self.blobID = blobID
    }
}

public struct TrustedDevice: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var publicKey: Data
    public var pairedAt: Date
    public var autoAccept: Bool
    public var notificationsEnabled: Bool

    public init(id: String, name: String, publicKey: Data, pairedAt: Date = .now,
                autoAccept: Bool = true, notificationsEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.publicKey = publicKey
        self.pairedAt = pairedAt
        self.autoAccept = autoAccept
        self.notificationsEnabled = notificationsEnabled
    }
}

public struct TossState: Codable, Sendable {
    public var devices: [TrustedDevice] = []
    public var transfers: [TransferItem] = []
    public var receivedIDs: Set<UUID> = []
    public var rejectedIDs: Set<UUID> = []
    public var cloudChangeToken: Data?
    public var cloudAccountID: String?
    public var pendingReceipts: [PendingReceipt] = []
    public var cloudLeases: [UUID: Date] = [:]
    public var cloudPendingDeletion: Set<UUID> = []
    public init() {}

    private enum CodingKeys: String, CodingKey { case devices, transfers, receivedIDs, rejectedIDs, cloudChangeToken, cloudAccountID, pendingReceipts, cloudLeases, cloudPendingDeletion }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        devices = try container.decodeIfPresent([TrustedDevice].self, forKey: .devices) ?? []
        transfers = try container.decodeIfPresent([TransferItem].self, forKey: .transfers) ?? []
        receivedIDs = try container.decodeIfPresent(Set<UUID>.self, forKey: .receivedIDs) ?? []
        rejectedIDs = try container.decodeIfPresent(Set<UUID>.self, forKey: .rejectedIDs) ?? []
        cloudChangeToken = try container.decodeIfPresent(Data.self, forKey: .cloudChangeToken)
        cloudAccountID = try container.decodeIfPresent(String.self, forKey: .cloudAccountID)
        pendingReceipts = try container.decodeIfPresent([PendingReceipt].self, forKey: .pendingReceipts) ?? []
        cloudLeases = try container.decodeIfPresent([UUID: Date].self, forKey: .cloudLeases) ?? [:]
        cloudPendingDeletion = try container.decodeIfPresent(Set<UUID>.self, forKey: .cloudPendingDeletion) ?? []
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(devices, forKey: .devices)
        try container.encode(transfers, forKey: .transfers)
        try container.encode(receivedIDs, forKey: .receivedIDs)
        try container.encode(rejectedIDs, forKey: .rejectedIDs)
        try container.encodeIfPresent(cloudChangeToken, forKey: .cloudChangeToken)
        try container.encodeIfPresent(cloudAccountID, forKey: .cloudAccountID)
        try container.encode(pendingReceipts, forKey: .pendingReceipts)
        try container.encode(cloudLeases, forKey: .cloudLeases)
        try container.encode(cloudPendingDeletion, forKey: .cloudPendingDeletion)
    }
}

public struct PendingReceipt: Codable, Sendable, Equatable {
    public let transferID: UUID
    public let senderID: String
    public let accepted: Bool

    public init(transferID: UUID, senderID: String, accepted: Bool) {
        self.transferID = transferID
        self.senderID = senderID
        self.accepted = accepted
    }
}

public enum TossError: LocalizedError, Equatable {
    case storageUnavailable, invalidContent, tooLarge, deviceUnavailable, untrustedDevice
    case invalidPairingCode, pairingExpired, authenticationFailed, corruptData

    public var errorDescription: String? {
        switch self {
        case .storageUnavailable: "Toss couldn't access its saved data. Unlock your device, check free storage, and try again."
        case .invalidContent: "This content can't be sent."
        case .tooLarge: "This file is larger than Toss's 20 MB limit."
        case .deviceUnavailable: "Delivery is temporarily unavailable. Toss will retry."
        case .untrustedDevice: "This device hasn't been paired."
        case .invalidPairingCode: "Couldn't verify this pairing code."
        case .pairingExpired: "This pairing code has expired."
        case .authenticationFailed: "Couldn't verify this device."
        case .corruptData: "The transfer couldn't be verified."
        }
    }
}
