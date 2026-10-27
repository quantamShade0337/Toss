import CryptoKit
import Foundation
import Darwin

public actor TransferRepository {
    private let directory: URL
    private let key: SymmetricKey
    private let stateURL: URL
    private let lockURL: URL
    private let blobDirectory: URL

    public init() throws {
        guard let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.ethansoh.toss") else {
            throw TossError.storageUnavailable
        }
        let rawKey = try KeychainVault.getOrCreate(account: "storage-v1", count: 32)
        try self.init(directory: directory, keyData: rawKey)
    }

    public init(directory: URL, keyData: Data) throws {
        guard keyData.count == 32 else { throw TossError.storageUnavailable }
        self.directory = directory
        key = SymmetricKey(data: keyData)
        stateURL = directory.appendingPathComponent("state.enc")
        lockURL = directory.appendingPathComponent("state.lock")
        blobDirectory = directory.appendingPathComponent("Blobs", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: blobDirectory, withIntermediateDirectories: true)
        Self.cleanStaleExports()
    }

    public func snapshot() throws -> TossState {
        try withLock { try readState() }
    }

    public func device(_ id: String) throws -> TrustedDevice? {
        try snapshot().devices.first { $0.id == id }
    }

    public func saveDevice(_ device: TrustedDevice) throws {
        guard device.id == LocalIdentity.fingerprint(device.publicKey) else { throw TossError.authenticationFailed }
        try mutate { state in
            state.devices.removeAll { $0.id == device.id }
            state.devices.append(device)
        }
    }

    public func forgetDevice(_ id: String) throws {
        try mutate { state in
            state.devices.removeAll { $0.id == id }
            state.pendingReceipts.removeAll { $0.senderID == id }
            for index in state.transfers.indices where state.transfers[index].receiverDeviceID == id
                && [.queued, .discovering, .sending, .sent, .waitingForDevice].contains(state.transfers[index].status) {
                if state.transfers[index].status == .waitingForDevice || state.cloudLeases[state.transfers[index].id] != nil {
                    state.cloudPendingDeletion.insert(state.transfers[index].id)
                }
                state.transfers[index].status = .failed
                state.transfers[index].failure = .untrustedDevice
            }
        }
    }

    public func saveCloudChangeToken(_ data: Data?) throws {
        try mutate { $0.cloudChangeToken = data }
    }

    public func bindCloudAccount(_ accountID: String, localDeviceID: String) throws {
        try mutate { state in
            if let previous = state.cloudAccountID, previous != accountID {
                state.cloudChangeToken = nil
                state.cloudLeases.removeAll()
                state.cloudPendingDeletion.removeAll()
                state.pendingReceipts.removeAll()
                for index in state.transfers.indices where state.transfers[index].senderDeviceID == localDeviceID
                    && state.transfers[index].status == .waitingForDevice {
                    state.transfers[index].status = .queued
                }
            }
            state.cloudAccountID = accountID
        }
    }

    public func queueReceipt(_ receipt: PendingReceipt) throws {
        try mutate { state in
            state.pendingReceipts.removeAll { $0.transferID == receipt.transferID }
            state.pendingReceipts.append(receipt)
        }
    }

    public func completeReceipt(_ transferID: UUID) throws {
        try mutate { $0.pendingReceipts.removeAll { $0.transferID == transferID } }
    }

    public func recordCloudLease(_ transferID: UUID, expiresAt: Date) throws {
        try mutate { $0.cloudLeases[transferID] = expiresAt }
    }

    /// Atomically commits upload only while the recipient is still trusted.
    /// A concurrent Forget Device leaves a durable deletion request instead.
    public func completeRemoteUpload(_ transferID: UUID, recipientID: String, expiresAt: Date) throws -> Bool {
        var committed = false
        try mutate { state in
            if let item = state.transfers.first(where: { $0.id == transferID }),
               item.receiverDeviceID == recipientID, item.status == .delivered {
                state.cloudPendingDeletion.insert(transferID)
                committed = true
                return
            }
            guard state.devices.contains(where: { $0.id == recipientID }),
                  let index = state.transfers.firstIndex(where: { $0.id == transferID }),
                  state.transfers[index].receiverDeviceID == recipientID,
                  [.queued, .sending, .sent].contains(state.transfers[index].status) else {
                state.cloudPendingDeletion.insert(transferID)
                return
            }
            state.transfers[index].status = .waitingForDevice
            state.transfers[index].failure = nil
            state.cloudLeases[transferID] = expiresAt
            committed = true
        }
        return committed
    }

    public func clearCloudLease(_ transferID: UUID) throws {
        try mutate {
            $0.cloudLeases.removeValue(forKey: transferID)
            $0.cloudPendingDeletion.remove(transferID)
        }
    }

    public func queueCloudDeletions(_ ids: Set<UUID>) throws {
        guard !ids.isEmpty else { return }
        try mutate { $0.cloudPendingDeletion.formUnion(ids) }
    }

    public func save(_ item: TransferItem) throws {
        try mutate { state in
            if let index = state.transfers.firstIndex(where: { $0.id == item.id }) {
                state.transfers[index] = item
            } else {
                state.transfers.append(item)
            }
        }
    }

    /// Keeps a replay record even after the visible transfer is deleted.
    @discardableResult
    public func recordIncoming(_ item: TransferItem, requiringTrustedSender: Bool = false) throws -> Bool {
        try withLock {
            var state = try readState()
            guard !requiringTrustedSender || state.devices.contains(where: { $0.id == item.senderDeviceID }) else {
                throw TossError.untrustedDevice
            }
            guard !state.receivedIDs.contains(item.id) else { return false }
            state.receivedIDs.insert(item.id)
            state.transfers.append(item)
            if item.status == .delivered {
                state.pendingReceipts.append(PendingReceipt(transferID: item.id, senderID: item.senderDeviceID, accepted: true))
            }
            try writeState(state)
            return true
        }
    }

    public func hasReceived(_ id: UUID) throws -> Bool {
        try snapshot().receivedIDs.contains(id)
    }

    public func rejectIncoming(_ id: UUID) throws {
        let old = try snapshot().transfers.first { $0.id == id }
        try mutate { state in
            state.receivedIDs.insert(id)
            state.rejectedIDs.insert(id)
            if let item = state.transfers.first(where: { $0.id == id }) {
                state.pendingReceipts.removeAll { $0.transferID == id }
                state.pendingReceipts.append(PendingReceipt(transferID: id, senderID: item.senderDeviceID, accepted: false))
            }
            state.transfers.removeAll { $0.id == id }
        }
        if let blobID = old?.blobID { removeBlob(blobID) }
    }

    public func updateStatus(_ id: UUID, to next: TransferStatus) throws {
        try mutate { state in
            guard let index = state.transfers.firstIndex(where: { $0.id == id }) else { return }
            guard state.transfers[index].status.canTransition(to: next) else { return }
            state.transfers[index].status = next
            if next == .sent { state.transfers[index].directAttemptedAt = .now }
            if next == .queued || next == .delivered { state.transfers[index].failure = nil }
            if next == .delivered {
                state.transfers[index].completedAt = .now
                if state.receivedIDs.contains(id) {
                    state.pendingReceipts.removeAll { $0.transferID == id }
                    state.pendingReceipts.append(PendingReceipt(transferID: id,
                        senderID: state.transfers[index].senderDeviceID, accepted: true))
                }
            }
        }
    }

    public func applyReceipt(_ id: UUID, senderID: String, localDeviceID: String, accepted: Bool) throws {
        try mutate { state in
            guard state.devices.contains(where: { $0.id == senderID }),
                  let index = state.transfers.firstIndex(where: { $0.id == id }),
                  state.transfers[index].senderDeviceID == localDeviceID,
                  state.transfers[index].receiverDeviceID == senderID else { throw TossError.authenticationFailed }
            let next: TransferStatus = accepted ? .delivered : .failed
            guard state.transfers[index].status.canTransition(to: next) else { return }
            state.transfers[index].status = next
            state.transfers[index].failure = accepted ? nil : .declined
            if accepted { state.transfers[index].completedAt = .now }
        }
    }

    public func recordFailure(_ id: UUID, issue: DeliveryIssue, terminal: Bool) throws {
        try mutate { state in
            guard let index = state.transfers.firstIndex(where: { $0.id == id }),
                  ![.delivered, .cancelled].contains(state.transfers[index].status) else { return }
            state.transfers[index].failure = issue
            state.transfers[index].status = terminal ? .failed : .queued
        }
    }

    /// Called once per engine lifetime, before any send starts. A terminated process
    /// cannot leave transfers permanently in a transient in-flight state.
    public func recoverInterruptedSends(localDeviceID: String) throws {
        try mutate { state in
            for index in state.transfers.indices where state.transfers[index].senderDeviceID == localDeviceID
                && [.discovering, .sending].contains(state.transfers[index].status) {
                state.transfers[index].status = .queued
            }
        }
    }

    public func receiptDecision(for id: UUID) throws -> Bool? {
        let state = try snapshot()
        guard state.receivedIDs.contains(id) else { return nil }
        if state.rejectedIDs.contains(id) { return false }
        // A deleted/pruned accepted item still needs an acknowledgement on replay.
        if let item = state.transfers.first(where: { $0.id == id }) { return item.status == .delivered ? true : nil }
        return true
    }

    public func markRead(_ id: UUID) throws {
        try mutate { state in
            guard let index = state.transfers.firstIndex(where: { $0.id == id }) else { return }
            state.transfers[index].isRead = true
        }
    }

    public func setArchived(_ id: UUID, _ archived: Bool) throws {
        try mutate { state in
            guard let index = state.transfers.firstIndex(where: { $0.id == id }) else { return }
            state.transfers[index].isArchived = archived
        }
    }

    public func delete(_ id: UUID) throws {
        let old = try snapshot().transfers.first { $0.id == id }
        try mutate { state in state.transfers.removeAll { $0.id == id } }
        if let blobID = old?.blobID {
            try? FileManager.default.removeItem(at: blobURL(blobID))
        }
    }

    public func clearHistory() throws {
        let blobs = try snapshot().transfers.compactMap(\.blobID)
        try mutate { state in
            for item in state.transfers where item.status == .queued && state.receivedIDs.contains(item.id) {
                state.rejectedIDs.insert(item.id)
            }
            state.transfers.removeAll()
        }
        for id in blobs { try? FileManager.default.removeItem(at: blobURL(id)) }
    }

    public func pruneHistory(olderThan cutoff: Date) throws {
        let expired = try snapshot().transfers.filter {
            $0.createdAt < cutoff && [.delivered, .failed, .cancelled].contains($0.status)
        }
        let ids = Set(expired.map(\.id))
        guard !ids.isEmpty else { return }
        try mutate { state in state.transfers.removeAll { ids.contains($0.id) } }
        for blobID in expired.compactMap(\.blobID) { removeBlob(blobID) }
    }

    public func removeBlob(_ id: UUID) {
        try? FileManager.default.removeItem(at: blobURL(id))
    }

    public func storeBlob(_ data: Data) throws -> UUID {
        try FileSafety.validate(data, typeIdentifier: nil)
        let id = UUID()
        let sealed = try AES.GCM.seal(data, using: key, authenticating: Data(id.uuidString.utf8))
        guard let combined = sealed.combined else { throw TossError.corruptData }
        try combined.write(to: blobURL(id), options: .atomic)
        protect(blobURL(id))
        return id
    }

    public func loadBlob(_ id: UUID) throws -> Data {
        let data = try Data(contentsOf: blobURL(id))
        let box = try AES.GCM.SealedBox(combined: data)
        return try AES.GCM.open(box, using: key, authenticating: Data(id.uuidString.utf8))
    }

    public func exportBlob(_ id: UUID, filename: String) throws -> URL {
        let data = try loadBlob(id)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TossPreviews", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(FileSafety.safeFilename(filename))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        protect(url)
        return url
    }

    public func removeExport(_ url: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TossPreviews", isDirectory: true)
        let parent = url.deletingLastPathComponent()
        guard parent.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: parent)
    }

    private func blobURL(_ id: UUID) -> URL { blobDirectory.appendingPathComponent(id.uuidString + ".enc") }

    private func mutate(_ change: (inout TossState) throws -> Void) throws {
        try withLock {
            var state = try readState()
            try change(&state)
            try writeState(state)
        }
    }

    private func withLock<T>(_ operation: () throws -> T) throws -> T {
        let fd = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw TossError.storageUnavailable }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw TossError.storageUnavailable }
        defer { flock(fd, LOCK_UN) }
        return try operation()
    }

    private func readState() throws -> TossState {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return TossState() }
        let data = try Data(contentsOf: stateURL)
        let box = try AES.GCM.SealedBox(combined: data)
        let plaintext = try AES.GCM.open(box, using: key, authenticating: Data("Toss state v1".utf8))
        return try JSONDecoder().decode(TossState.self, from: plaintext)
    }

    private func writeState(_ state: TossState) throws {
        let plaintext = try JSONEncoder().encode(state)
        let box = try AES.GCM.seal(plaintext, using: key, authenticating: Data("Toss state v1".utf8))
        guard let combined = box.combined else { throw TossError.corruptData }
        try combined.write(to: stateURL, options: .atomic)
        protect(stateURL)
    }

    private func protect(_ url: URL) {
        #if os(iOS)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                               ofItemAtPath: url.path)
        #endif
    }

    private static func cleanStaleExports() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TossPreviews", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey]) else { return }
        for entry in entries {
            let created = (try? entry.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            if created < Date.now.addingTimeInterval(-3_600) { try? FileManager.default.removeItem(at: entry) }
        }
    }
}
