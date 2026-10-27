import CloudKit
import Foundation

/// CloudKit is an untrusted mailbox. Every asset is an already authenticated, encrypted envelope.
/// Only routing fingerprints and expiry dates are stored in record fields.
public enum RemoteAvailability: Equatable, Sendable {
    case checking, available, unavailable
}

public struct CloudChangePage {
    public let records: [CKRecord]
    public let token: Data?
    public let moreComing: Bool
}

private final class ChangeCollector {
    let lock = NSLock()
    var records: [CKRecord] = []
    var token: CKServerChangeToken?
    var moreComing = false
    var zoneError: Error?

    func append(_ record: CKRecord) { lock.lock(); records.append(record); lock.unlock() }
    func finish(token: CKServerChangeToken?, moreComing: Bool, error: Error?) {
        lock.lock()
        self.token = token
        self.moreComing = moreComing
        if let error { zoneError = error }
        lock.unlock()
    }

    func snapshot() -> ([CKRecord], CKServerChangeToken?, Bool, Error?) {
        lock.lock()
        defer { lock.unlock() }
        return (records, token, moreComing, zoneError)
    }
}

@MainActor
public protocol RemoteTransferTransport {
    func prepare() async throws -> String
    func accountStatus() async throws -> CKAccountStatus
    func uploadTransfer(_ envelope: SecureEnvelope, transferID: UUID) async throws
    func uploadReceipt(_ envelope: SecureEnvelope, transferID: UUID) async throws
    func changes(since encodedToken: Data?) async throws -> CloudChangePage
    func existingTransfer(_ id: UUID) async throws -> SecureEnvelope
    func existingReceipt(_ id: UUID) async throws -> SecureEnvelope
    func deleteTransfer(_ id: UUID) async throws
    func deleteReceipt(_ id: UUID) async throws
}

@MainActor
public final class CloudTransferTransport: RemoteTransferTransport {
    nonisolated public static let containerIdentifier = "iCloud.com.ethansoh.toss"
    nonisolated public static let zoneName = "TossTransfers"
    nonisolated public static let transferType = "EncryptedTransfer"
    nonisolated public static let receiptType = "EncryptedReceipt"
    nonisolated private static let subscriptionID = "toss-transfers-v1"
    nonisolated private static let maximumEnvelopeBytes = 21 * 1_024 * 1_024

    private let container: CKContainer
    private let database: CKDatabase
    private let zoneID = CKRecordZone.ID(zoneName: zoneName)
    private var prepared = false
    private var preparedAccountID: String?

    public init() {
        container = CKContainer(identifier: Self.containerIdentifier)
        database = container.privateCloudDatabase
    }

    public func prepare() async throws -> String {
        let status = try await accountStatus()
        guard status == .available else { throw CKError(status == .noAccount ? .notAuthenticated : .serviceUnavailable) }
        let accountID = try await accountRecordName()
        if prepared && preparedAccountID == accountID { return accountID }
        let zoneExists: Bool
        do {
            _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CKRecordZone, Error>) in
                database.fetch(withRecordZoneID: zoneID) { existing, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let existing { continuation.resume(returning: existing) }
                    else { continuation.resume(throwing: TossError.storageUnavailable) }
                }
            }
            zoneExists = true
        } catch let error as CKError where error.code == .zoneNotFound {
            zoneExists = false
        }
        if !zoneExists {
            let zone = CKRecordZone(zoneID: zoneID)
            _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CKRecordZone, Error>) in
                database.save(zone) { saved, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let saved { continuation.resume(returning: saved) }
                    else { continuation.resume(throwing: TossError.storageUnavailable) }
                }
            }
        }
        let subscriptionExists: Bool
        do {
            _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CKSubscription, Error>) in
                database.fetch(withSubscriptionID: Self.subscriptionID) { existing, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let existing { continuation.resume(returning: existing) }
                    else { continuation.resume(throwing: TossError.storageUnavailable) }
                }
            }
            subscriptionExists = true
        } catch let error as CKError where error.code == .unknownItem {
            subscriptionExists = false
        }
        if !subscriptionExists {
            let subscription = CKRecordZoneSubscription(zoneID: zoneID, subscriptionID: Self.subscriptionID)
            let info = CKSubscription.NotificationInfo()
            info.shouldSendContentAvailable = true
            subscription.notificationInfo = info
            _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CKSubscription, Error>) in
                database.save(subscription) { saved, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let saved { continuation.resume(returning: saved) }
                    else { continuation.resume(throwing: TossError.storageUnavailable) }
                }
            }
        }
        prepared = true
        preparedAccountID = accountID
        return accountID
    }

    public func accountStatus() async throws -> CKAccountStatus {
        try await withCheckedThrowingContinuation { continuation in
            container.accountStatus { status, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: status) }
            }
        }
    }

    public func accountRecordName() async throws -> String {
        let recordID = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CKRecord.ID, Error>) in
            container.fetchUserRecordID { id, error in
                if let error { continuation.resume(throwing: error) }
                else if let id { continuation.resume(returning: id) }
                else { continuation.resume(throwing: TossError.storageUnavailable) }
            }
        }
        return recordID.recordName
    }

    public func uploadTransfer(_ envelope: SecureEnvelope, transferID: UUID) async throws {
        try await upload(envelope, type: Self.transferType, recordName: "transfer-\(transferID.uuidString)",
                         expiresAt: .now.addingTimeInterval(30 * 86_400))
    }

    public func uploadReceipt(_ envelope: SecureEnvelope, transferID: UUID) async throws {
        try await upload(envelope, type: Self.receiptType, recordName: "receipt-\(transferID.uuidString)",
                         expiresAt: .now.addingTimeInterval(30 * 86_400))
    }

    private func upload(_ envelope: SecureEnvelope, type: String, recordName: String, expiresAt: Date) async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".tossenc")
        let limit = Self.maximumEnvelopeBytes
        try await Task.detached(priority: .userInitiated) {
            let data = try PropertyListEncoder().encode(envelope)
            guard data.count <= limit else { throw TossError.tooLarge }
            try data.write(to: file, options: .atomic)
        }.value
        defer { try? FileManager.default.removeItem(at: file) }
        let id = CKRecord.ID(recordName: recordName, zoneID: zoneID)
        let record = CKRecord(recordType: type, recordID: id)
        record["sender"] = envelope.senderID as CKRecordValue
        record["recipient"] = envelope.receiverID as CKRecordValue
        record["expiresAt"] = expiresAt as CKRecordValue
        record["envelope"] = CKAsset(fileURL: file)
        _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CKRecord, Error>) in
            database.save(record) { saved, error in
                if let error { continuation.resume(throwing: error) }
                else if let saved { continuation.resume(returning: saved) }
                else { continuation.resume(throwing: TossError.storageUnavailable) }
            }
        }
    }

    public func changes(since encodedToken: Data?) async throws -> CloudChangePage {
        let token: CKServerChangeToken?
        if let encodedToken {
            token = try NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: encodedToken)
        } else { token = nil }
        let config = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
        config.previousServerChangeToken = token
        let op = CKFetchRecordZoneChangesOperation(recordZoneIDs: [zoneID], configurationsByRecordZoneID: [zoneID: config])
        let collector = ChangeCollector()
        op.recordWasChangedBlock = { _, result in
            if case .success(let record) = result { collector.append(record) }
            else if case .failure(let error) = result { collector.finish(token: nil, moreComing: false, error: error) }
        }
        op.recordZoneFetchResultBlock = { _, result in
            switch result {
            case .success(let value): collector.finish(token: value.serverChangeToken, moreComing: value.moreComing, error: nil)
            case .failure(let error): collector.finish(token: nil, moreComing: false, error: error)
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            op.fetchRecordZoneChangesResultBlock = { result in continuation.resume(with: result) }
            database.add(op)
        }
        let (records, nextToken, moreComing, zoneError) = collector.snapshot()
        if let zoneError { throw zoneError }
        let encoded = try nextToken.map { try NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
        return CloudChangePage(records: records, token: encoded, moreComing: moreComing)
    }

    public func envelope(from record: CKRecord) throws -> SecureEnvelope {
        try Self.decodeEnvelope(from: record)
    }

    nonisolated public static func decodeEnvelope(from record: CKRecord) throws -> SecureEnvelope {
        guard record.recordID.zoneID == CKRecordZone.ID(zoneName: zoneName),
              record.recordType == Self.transferType || record.recordType == Self.receiptType,
              let asset = record["envelope"] as? CKAsset, let file = asset.fileURL else { throw TossError.corruptData }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maximumEnvelopeBytes + 1) ?? Data()
        guard !data.isEmpty, data.count <= Self.maximumEnvelopeBytes else { throw TossError.tooLarge }
        let envelope: SecureEnvelope
        do { envelope = try PropertyListDecoder().decode(SecureEnvelope.self, from: data) }
        catch { throw TossError.corruptData }
        let prefix = record.recordType == Self.transferType ? "transfer-" : "receipt-"
        guard record.recordID.recordName.hasPrefix(prefix),
              UUID(uuidString: String(record.recordID.recordName.dropFirst(prefix.count))) != nil,
              record["sender"] as? String == envelope.senderID,
              record["recipient"] as? String == envelope.receiverID else { throw TossError.authenticationFailed }
        return envelope
    }

    public func existingTransfer(_ id: UUID) async throws -> SecureEnvelope {
        try await existing(type: Self.transferType, recordName: "transfer-\(id.uuidString)")
    }

    public func existingReceipt(_ id: UUID) async throws -> SecureEnvelope {
        try await existing(type: Self.receiptType, recordName: "receipt-\(id.uuidString)")
    }

    private func existing(type: String, recordName: String) async throws -> SecureEnvelope {
        let id = CKRecord.ID(recordName: recordName, zoneID: zoneID)
        let record = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CKRecord, Error>) in
            database.fetch(withRecordID: id) { record, error in
                if let error { continuation.resume(throwing: error) }
                else if let record { continuation.resume(returning: record) }
                else { continuation.resume(throwing: TossError.corruptData) }
            }
        }
        guard record.recordType == type else { throw TossError.authenticationFailed }
        return try envelope(from: record)
    }

    public func deleteTransfer(_ id: UUID) async throws {
        try await delete(recordName: "transfer-\(id.uuidString)")
    }

    public func deleteReceipt(_ id: UUID) async throws {
        try await delete(recordName: "receipt-\(id.uuidString)")
    }

    private func delete(recordName: String) async throws {
        let id = CKRecord.ID(recordName: recordName, zoneID: zoneID)
        _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CKRecord.ID, Error>) in
            database.delete(withRecordID: id) { deleted, error in
                if let error { continuation.resume(throwing: error) }
                else if let deleted { continuation.resume(returning: deleted) }
                else { continuation.resume(throwing: TossError.storageUnavailable) }
            }
        }
    }
}
