import CryptoKit
import CloudKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import TossCore

@Test func classifiesCommonContent() {
    #expect(ContentClassifier.classify("https://example.com/a").kind == .link)
    #expect(ContentClassifier.classify("313 Orchard Road").kind == .location)
    #expect(ContentClassifier.classify("hello@example.com").kind == .email)
    #expect(ContentClassifier.classify("+65 9123 4567").kind == .phone)
    #expect(ContentClassifier.classify("Dinner tomorrow at 7 PM").kind == .event)
    #expect(ContentClassifier.classify("func toss() {\n print(1)\n}").kind == .code)
    #expect(ContentClassifier.classify("javascript:alert(1)").kind == .text)
}

@Test func sanitizesFileNamesAndTransitions() {
    #expect(FileSafety.safeFilename("../../secret.pdf") == "secret.pdf")
    #expect(FileSafety.safeFilename("..\\..\\notes.txt") == "notes.txt")
    #expect(!TransferStatus.delivered.canTransition(to: .sending))
    #expect(TransferStatus.sent.canTransition(to: .delivered))
}

@Test func authenticatedTransferRejectsTampering() throws {
    let alice = LocalIdentity(privateKey: Curve25519.KeyAgreement.PrivateKey())
    let bob = LocalIdentity(privateKey: Curve25519.KeyAgreement.PrivateKey())
    let bobRecord = TrustedDevice(id: bob.id, name: "Bob", publicKey: bob.publicKey)
    let aliceRecord = TrustedDevice(id: alice.id, name: "Alice", publicKey: alice.publicKey)
    let payload = Data("private text".utf8)
    let envelope = try CryptoBox.seal(payload, from: alice, to: bobRecord)
    #expect(try CryptoBox.open(envelope, local: bob, from: aliceRecord) == payload)
    let forged = SecureEnvelope(id: envelope.id, senderID: envelope.senderID,
                                receiverID: envelope.receiverID, salt: envelope.salt,
                                sealed: envelope.sealed + Data([0]))
    #expect(throws: Error.self) { try CryptoBox.open(forged, local: bob, from: aliceRecord) }
    let renamed = SecureEnvelope(id: UUID(), senderID: envelope.senderID,
                                 receiverID: envelope.receiverID, salt: envelope.salt,
                                 sealed: envelope.sealed)
    #expect(throws: Error.self) { try CryptoBox.open(renamed, local: bob, from: aliceRecord) }
}

@Test func pairingCodeAuthenticatesJoiner() throws {
    let mac = LocalIdentity(privateKey: Curve25519.KeyAgreement.PrivateKey())
    let phone = LocalIdentity(privateKey: Curve25519.KeyAgreement.PrivateKey())
    let offer = PairingOffer(identity: mac, deviceName: "Mac", secret: Data(repeating: 5, count: 32),
                             expiresAt: .now.addingTimeInterval(300))
    let parsed = try PairingOffer(url: #require(offer.url))
    #expect(parsed.deviceID == mac.id)
    #expect(parsed.verificationCode == LocalIdentity.verificationCode(mac.publicKey))
    #expect(parsed.verificationCode != LocalIdentity.verificationCode(phone.publicKey))
    let hello = PairingHello(identity: phone, deviceName: "Phone", offer: parsed)
    #expect(hello.verify(offer: offer))
    let wrong = PairingOffer(identity: mac, deviceName: "Mac", secret: Data(repeating: 6, count: 32),
                             expiresAt: offer.expiresAt)
    #expect(!hello.verify(offer: wrong))
    let expired = PairingOffer(identity: mac, deviceName: "Mac", secret: offer.secret,
                               expiresAt: .now.addingTimeInterval(-1))
    #expect(!hello.verify(offer: expired))
}

@Test func encryptedHistoryPersistsAndUpdates() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let key = Data(repeating: 7, count: 32)
    let repository = try TransferRepository(directory: directory, keyData: key)
    let item = TransferItem(senderDeviceID: "a", receiverDeviceID: "b", kind: .text,
                            title: "Hello", text: "Hello")
    try await repository.save(item)
    try await repository.updateStatus(item.id, to: .discovering)
    let reopened = try TransferRepository(directory: directory, keyData: key)
    let state = try await reopened.snapshot()
    #expect(state.transfers.first?.status == .discovering)
    let disk = try Data(contentsOf: directory.appendingPathComponent("state.enc"))
    #expect(!disk.contains(Data("Hello".utf8)))
    let received = TransferItem(senderDeviceID: "b", receiverDeviceID: "a", kind: .text,
                                title: "Once", text: "Once", status: .delivered)
    #expect(try await repository.recordIncoming(received))
    try await repository.delete(received.id)
    let reopenedAgain = try TransferRepository(directory: directory, keyData: key)
    #expect(try await reopenedAgain.hasReceived(received.id))
    #expect(try await !reopenedAgain.recordIncoming(received))
    let pending = TransferItem(senderDeviceID: "b", receiverDeviceID: "a", kind: .text,
                               title: "Review", text: "Review", status: .queued)
    #expect(try await reopenedAgain.recordIncoming(pending))
    try await reopenedAgain.rejectIncoming(pending.id)
    let rejected = try await reopenedAgain.snapshot()
    #expect(rejected.rejectedIDs.contains(pending.id))
    #expect(!rejected.transfers.contains { $0.id == pending.id })
    let old = TransferItem(createdAt: .now.addingTimeInterval(-100 * 86_400),
                           senderDeviceID: "a", receiverDeviceID: "b", kind: .text,
                           title: "Old", text: "Old", status: .delivered)
    let stillQueued = TransferItem(createdAt: .now.addingTimeInterval(-100 * 86_400),
                                   senderDeviceID: "a", receiverDeviceID: "b", kind: .text,
                                   title: "Pending", text: "Pending")
    try await reopenedAgain.save(old)
    try await reopenedAgain.save(stillQueued)
    try await reopenedAgain.pruneHistory(olderThan: .now.addingTimeInterval(-30 * 86_400))
    let pruned = try await reopenedAgain.snapshot()
    #expect(!pruned.transfers.contains { $0.id == old.id })
    #expect(pruned.transfers.contains { $0.id == stillQueued.id })
}

@Test func wireFormatRoundTripsAndRejectsWrongRecipient() throws {
    let alice = LocalIdentity(privateKey: Curve25519.KeyAgreement.PrivateKey())
    let bob = LocalIdentity(privateKey: Curve25519.KeyAgreement.PrivateKey())
    let eve = LocalIdentity(privateKey: Curve25519.KeyAgreement.PrivateKey())
    let bobRecord = TrustedDevice(id: bob.id, name: "Bob", publicKey: bob.publicKey)
    let aliceRecord = TrustedDevice(id: alice.id, name: "Alice", publicKey: alice.publicKey)
    let message = WireMessage.transfer(try CryptoBox.seal(Data("hello".utf8), from: alice, to: bobRecord))
    let encoded = try PropertyListEncoder().encode(message)
    let decoded = try PropertyListDecoder().decode(WireMessage.self, from: encoded)
    guard case .transfer(let packet) = decoded else { Issue.record("Wrong message type"); return }
    #expect(try CryptoBox.open(packet, local: bob, from: aliceRecord) == Data("hello".utf8))
    #expect(throws: Error.self) { try CryptoBox.open(packet, local: eve, from: aliceRecord) }
}

@Test func rejectsMislabeledFiles() {
    #expect(throws: Error.self) { try FileSafety.validate(Data("not an image".utf8), typeIdentifier: UTType.jpeg.identifier) }
    #expect(throws: Error.self) { try FileSafety.validate(Data("not a pdf".utf8), typeIdentifier: UTType.pdf.identifier) }
    #expect(throws: Error.self) { try FileSafety.validate(Data(), typeIdentifier: nil) }
    #expect(throws: Error.self) { try FileSafety.validate(Data("data".utf8), typeIdentifier: "invalid type id") }
}

@Test func rejectsHugeFileBeforeReadingIt() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    FileManager.default.createFile(atPath: file.path, contents: nil)
    let handle = try FileHandle(forWritingTo: file)
    try handle.truncate(atOffset: UInt64(FileSafety.maximumBytes + 1))
    try handle.close()
    #expect(throws: TossError.tooLarge) { try FileSafety.load(file) }
}

@Test func rejectsSpoofedIncomingMetadata() throws {
    let valid = TransferItem(senderDeviceID: "sender", receiverDeviceID: "receiver", kind: .link,
                             title: "example.com", text: "https://example.com",
                             sourceURL: URL(string: "https://example.com"), byteCount: 19)
    try IncomingValidator.validate(valid, data: nil, senderID: "sender", receiverID: "receiver")
    #expect(throws: Error.self) {
        try IncomingValidator.validate(valid, data: nil, senderID: "intruder", receiverID: "receiver")
    }
    var forged = valid
    forged.sourceURL = URL(string: "file:///etc/passwd")
    #expect(throws: Error.self) {
        try IncomingValidator.validate(forged, data: nil, senderID: "sender", receiverID: "receiver")
    }
    forged = valid
    forged.kind = .email
    #expect(throws: Error.self) {
        try IncomingValidator.validate(forged, data: nil, senderID: "sender", receiverID: "receiver")
    }
    forged = valid
    forged.createdAt = .now.addingTimeInterval(-31 * 86_400)
    #expect(throws: Error.self) {
        try IncomingValidator.validate(forged, data: nil, senderID: "sender", receiverID: "receiver")
    }
    forged = valid
    forged.createdAt = .now.addingTimeInterval(600)
    #expect(throws: Error.self) {
        try IncomingValidator.validate(forged, data: nil, senderID: "sender", receiverID: "receiver")
    }
}

@Test @MainActor func cloudAssetStaysEncryptedAndBindsRouting() throws {
    let sender = LocalIdentity(privateKey: Curve25519.KeyAgreement.PrivateKey())
    let receiver = LocalIdentity(privateKey: Curve25519.KeyAgreement.PrivateKey())
    let receiverRecord = TrustedDevice(id: receiver.id, name: "Phone", publicKey: receiver.publicKey)
    let senderRecord = TrustedDevice(id: sender.id, name: "Mac", publicKey: sender.publicKey)
    let secret = Data("private filename and content".utf8)
    let envelope = try CryptoBox.seal(secret, from: sender, to: receiverRecord)
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    try PropertyListEncoder().encode(envelope).write(to: file)
    let disk = try Data(contentsOf: file)
    #expect(!disk.contains(secret))
    let zone = CKRecordZone.ID(zoneName: CloudTransferTransport.zoneName)
    let record = CKRecord(recordType: CloudTransferTransport.transferType,
                          recordID: CKRecord.ID(recordName: "transfer-\(UUID().uuidString)", zoneID: zone))
    record["sender"] = sender.id as CKRecordValue
    record["recipient"] = receiver.id as CKRecordValue
    record["envelope"] = CKAsset(fileURL: file)
    let decoded = try CloudTransferTransport.decodeEnvelope(from: record)
    #expect(try CryptoBox.open(decoded, local: receiver, from: senderRecord) == secret)
    record["recipient"] = sender.id as CKRecordValue
    #expect(throws: Error.self) { try CloudTransferTransport.decodeEnvelope(from: record) }
}

@Test func remoteQueueAndReplayLedgerSurviveRestart() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let key = Data(repeating: 9, count: 32)
    let store = try TransferRepository(directory: directory, keyData: key)
    let sender = LocalIdentity(privateKey: Curve25519.KeyAgreement.PrivateKey())
    let device = TrustedDevice(id: sender.id, name: "Mac", publicKey: sender.publicKey)
    try await store.saveDevice(device)
    try await store.saveDevice(device)
    #expect(try await store.snapshot().devices.count == 1)
    let id = UUID()
    try await store.queueReceipt(PendingReceipt(transferID: id, senderID: sender.id, accepted: true))
    try await store.saveCloudChangeToken(Data([1, 2, 3]))
    try await store.recordCloudLease(id, expiresAt: .now)
    let outbound = TransferItem(senderDeviceID: sender.id, receiverDeviceID: "other", kind: .text,
                                title: "Queued", text: "Queued", status: .waitingForDevice)
    try await store.save(outbound)
    let reopened = try TransferRepository(directory: directory, keyData: key)
    let state = try await reopened.snapshot()
    #expect(state.pendingReceipts.count == 1)
    #expect(state.cloudChangeToken == Data([1, 2, 3]))
    #expect(state.cloudLeases[id] != nil)
    try await reopened.bindCloudAccount("first", localDeviceID: sender.id)
    try await reopened.bindCloudAccount("second", localDeviceID: sender.id)
    let switched = try await reopened.snapshot()
    #expect(switched.cloudChangeToken == nil)
    #expect(switched.cloudLeases.isEmpty)
    #expect(switched.pendingReceipts.isEmpty)
    #expect(switched.transfers.first { $0.id == outbound.id }?.status == .queued)
    try await reopened.forgetDevice(sender.id)
    #expect(try await reopened.snapshot().pendingReceipts.isEmpty)
    #expect(try await reopened.device(sender.id) == nil)
    #expect(TransferStatus.waitingForDevice.canTransition(to: .delivered))
}

@Test func coordinatorPrefersNearbyAndFailsOverAfterReceiptTimeout() {
    var item = TransferItem(senderDeviceID: "a", receiverDeviceID: "b", kind: .text,
                            title: "Hello", text: "Hello")
    #expect(TransferCoordinator.route(for: item, trusted: true, nearbyConnected: true,
                                      remoteAvailable: true) == .nearby)
    #expect(TransferCoordinator.route(for: item, trusted: true, nearbyConnected: false,
                                      remoteAvailable: true) == .remote)
    #expect(TransferCoordinator.route(for: item, trusted: true, nearbyConnected: false,
                                      remoteAvailable: false) == .queued)
    #expect(TransferCoordinator.route(for: item, trusted: false, nearbyConnected: true,
                                      remoteAvailable: true) == .reject)
    item.status = .sent
    item.directAttemptedAt = .now.addingTimeInterval(-6)
    #expect(TransferCoordinator.route(for: item, trusted: true, nearbyConnected: true,
                                      remoteAvailable: true) == .remote)
}

@Test func forgettingDeviceQueuesRemoteRevocation() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try TransferRepository(directory: directory, keyData: Data(repeating: 4, count: 32))
    let peer = LocalIdentity(privateKey: Curve25519.KeyAgreement.PrivateKey())
    try await store.saveDevice(TrustedDevice(id: peer.id, name: "Peer", publicKey: peer.publicKey))
    let item = TransferItem(senderDeviceID: "local", receiverDeviceID: peer.id, kind: .text,
                            title: "Pending", text: "Pending", status: .sending)
    try await store.save(item)
    #expect(try await store.completeRemoteUpload(item.id, recipientID: peer.id,
                                                 expiresAt: .now.addingTimeInterval(86_400)))
    try await store.forgetDevice(peer.id)
    let state = try await store.snapshot()
    #expect(state.devices.isEmpty)
    #expect(state.transfers.first?.status == .failed)
    #expect(state.cloudPendingDeletion.contains(item.id))
    let late = TransferItem(senderDeviceID: "local", receiverDeviceID: peer.id, kind: .text,
                            title: "Late", text: "Late", status: .sending)
    try await store.save(late)
    #expect(try await !store.completeRemoteUpload(late.id, recipientID: peer.id,
                                                  expiresAt: .now.addingTimeInterval(86_400)))
    #expect(try await store.snapshot().cloudPendingDeletion.contains(late.id))
    try await store.clearCloudLease(item.id)
    #expect(try await !store.snapshot().cloudPendingDeletion.contains(item.id))
}

@Test func senderCanVerifyExistingUploadWithoutWeakeningReceiverChecks() throws {
    let alice = LocalIdentity(privateKey: Curve25519.KeyAgreement.PrivateKey())
    let bob = LocalIdentity(privateKey: Curve25519.KeyAgreement.PrivateKey())
    let peer = TrustedDevice(id: bob.id, name: "Bob", publicKey: bob.publicKey)
    let envelope = try CryptoBox.seal(Data("private".utf8), from: alice, to: peer)
    #expect(try CryptoBox.openSent(envelope, local: alice, to: peer) == Data("private".utf8))
    #expect(throws: Error.self) { try CryptoBox.open(envelope, local: alice, from: peer) }
    let forged = SecureEnvelope(id: envelope.id, senderID: envelope.senderID, receiverID: envelope.receiverID,
                                salt: envelope.salt, sealed: envelope.sealed + Data([0]))
    #expect(throws: Error.self) { try CryptoBox.openSent(forged, local: alice, to: peer) }
}

@Test func restartRecoversOnlyInterruptedOutboundItems() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try TransferRepository(directory: directory, keyData: Data(repeating: 9, count: 32))
    for (sender, status) in [("local", TransferStatus.sending), ("local", .discovering), ("local", .delivered), ("peer", .queued)] {
        try await store.save(TransferItem(senderDeviceID: sender, receiverDeviceID: "peer", kind: .text, title: "Test", status: status))
    }
    try await store.recoverInterruptedSends(localDeviceID: "local")
    let state = try await store.snapshot()
    #expect(state.transfers.filter { $0.senderDeviceID == "local" && $0.status == .queued }.count == 2)
    #expect(state.transfers.filter { $0.status == .delivered }.count == 1)
    #expect(state.transfers.first { $0.senderDeviceID == "peer" }?.status == .queued)
}

@Test func receiptIsDurableWithAcceptanceAndSurvivesHistoryDeletion() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try TransferRepository(directory: directory, keyData: Data(repeating: 2, count: 32))
    let item = TransferItem(senderDeviceID: "peer", receiverDeviceID: "local", kind: .text, title: "Review")
    #expect(try await store.recordIncoming(item))
    #expect(try await store.receiptDecision(for: item.id) == nil)
    try await store.updateStatus(item.id, to: .delivered)
    #expect(try await store.snapshot().pendingReceipts == [PendingReceipt(transferID: item.id, senderID: "peer", accepted: true)])
    try await store.delete(item.id)
    #expect(try await store.receiptDecision(for: item.id) == true)
    #expect(try await !store.recordIncoming(item))
}

@Test func acknowledgementWinningUploadRaceRemainsDelivered() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try TransferRepository(directory: directory, keyData: Data(repeating: 2, count: 32))
    let peer = LocalIdentity(privateKey: Curve25519.KeyAgreement.PrivateKey())
    try await store.saveDevice(TrustedDevice(id: peer.id, name: "Phone", publicKey: peer.publicKey))
    let item = TransferItem(senderDeviceID: "local", receiverDeviceID: peer.id, kind: .text, title: "Race", status: .sending)
    try await store.save(item)
    try await store.updateStatus(item.id, to: .delivered)
    #expect(try await store.completeRemoteUpload(item.id, recipientID: peer.id, expiresAt: .now.addingTimeInterval(300)))
    try await store.recordFailure(item.id, issue: .offline, terminal: false)
    #expect(try await store.snapshot().transfers.first?.status == .delivered)
    #expect(try await store.snapshot().cloudPendingDeletion.contains(item.id))
}

@Test(arguments: [(CKError.Code.notAuthenticated, DeliveryIssue.signIn), (.quotaExceeded, .cloudStorage),
                  (.networkUnavailable, .offline), (.missingEntitlement, .configuration)])
func failuresHaveSpecificSafeRecovery(code: CKError.Code, expected: DeliveryIssue) {
    let error = CKError(code, userInfo: [NSLocalizedDescriptionKey: "private/secret/path"])
    let issue = DeliveryIssue(error: error)
    #expect(issue == expected)
    #expect(!issue.guidance.contains("secret"))
    #expect(!issue.guidance.isEmpty)
}

@MainActor
private final class MailboxStub: RemoteTransferTransport {
    var uploadError: CKError?
    var transfers: [UUID: SecureEnvelope] = [:]
    var receipts: [UUID: SecureEnvelope] = [:]
    var records: [CKRecord] = []
    var uploadCount = 0
    func prepare() async throws -> String { "test-account" }
    func accountStatus() async throws -> CKAccountStatus { .available }
    func uploadTransfer(_ envelope: SecureEnvelope, transferID: UUID) async throws {
        uploadCount += 1
        if let uploadError { throw uploadError }
        if transfers[transferID] != nil { throw CKError(.serverRecordChanged) }
        transfers[transferID] = envelope
    }
    func uploadReceipt(_ envelope: SecureEnvelope, transferID: UUID) async throws {
        if receipts[transferID] != nil { throw CKError(.serverRecordChanged) }
        receipts[transferID] = envelope
    }
    func changes(since encodedToken: Data?) async throws -> CloudChangePage {
        CloudChangePage(records: records, token: Data([42]), moreComing: false)
    }
    func existingTransfer(_ id: UUID) async throws -> SecureEnvelope { try #require(transfers[id]) }
    func existingReceipt(_ id: UUID) async throws -> SecureEnvelope { try #require(receipts[id]) }
    func deleteTransfer(_ id: UUID) async throws { transfers[id] = nil }
    func deleteReceipt(_ id: UUID) async throws { receipts[id] = nil }
}

@Test @MainActor func remoteRetryUsesSameTransferAndHandlesExistingEncryptedUpload() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try TransferRepository(directory: directory, keyData: Data(repeating: 8, count: 32))
    let local = LocalIdentity(privateKey: Curve25519.KeyAgreement.PrivateKey())
    let peer = LocalIdentity(privateKey: Curve25519.KeyAgreement.PrivateKey())
    let device = TrustedDevice(id: peer.id, name: "Phone", publicKey: peer.publicKey)
    try await store.saveDevice(device)
    let item = TransferItem(senderDeviceID: local.id, receiverDeviceID: peer.id, kind: .text, title: "Hello", text: "Hello", byteCount: 5)
    try await store.save(item)
    let mailbox = MailboxStub()
    mailbox.uploadError = CKError(.networkUnavailable)
    let engine = try TossEngine(identity: local, repository: store, name: "Test", remoteTransport: mailbox)
    await engine.syncRemote()
    #expect(try await store.snapshot().transfers.first?.status == .queued)
    #expect(try await store.snapshot().transfers.first?.failure == .offline)
    mailbox.uploadError = nil
    // Server accepted an earlier attempt but the client never saw its response.
    mailbox.transfers[item.id] = try CryptoBox.seal(PropertyListEncoder().encode(TransferPayload(item: item, data: nil)), from: local, to: device)
    await engine.flush()
    let state = try await store.snapshot()
    #expect(state.transfers.count == 1)
    #expect(state.transfers.first?.id == item.id)
    #expect(state.transfers.first?.status == .waitingForDevice)
    #expect(mailbox.uploadCount == 2)
}

@Test @MainActor func malformedRemoteRecordDoesNotBlockFollowingTransferOrToken() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try TransferRepository(directory: directory, keyData: Data(repeating: 8, count: 32))
    let local = LocalIdentity(privateKey: Curve25519.KeyAgreement.PrivateKey())
    let peer = LocalIdentity(privateKey: Curve25519.KeyAgreement.PrivateKey())
    try await store.saveDevice(TrustedDevice(id: peer.id, name: "Phone", publicKey: peer.publicKey))
    let recipient = TrustedDevice(id: local.id, name: "Mac", publicKey: local.publicKey)
    let item = TransferItem(senderDeviceID: peer.id, receiverDeviceID: local.id, kind: .text, title: "Hello", text: "Hello", byteCount: 5)
    let valid = try CryptoBox.seal(PropertyListEncoder().encode(TransferPayload(item: item, data: nil)), from: peer, to: recipient)
    let invalid = SecureEnvelope(senderID: peer.id, receiverID: local.id, salt: Data(repeating: 0, count: 32), sealed: Data([0]))
    let mailbox = MailboxStub()
    for (id, envelope) in [(UUID(), invalid), (item.id, valid)] {
        let file = directory.appendingPathComponent(id.uuidString)
        try PropertyListEncoder().encode(envelope).write(to: file)
        let record = CKRecord(recordType: CloudTransferTransport.transferType,
            recordID: CKRecord.ID(recordName: "transfer-\(id)", zoneID: CKRecordZone.ID(zoneName: CloudTransferTransport.zoneName)))
        record["sender"] = peer.id
        record["recipient"] = local.id
        record["envelope"] = CKAsset(fileURL: file)
        mailbox.records.append(record)
    }
    let engine = try TossEngine(identity: local, repository: store, name: "Test", remoteTransport: mailbox)
    await engine.syncRemote()
    let state = try await store.snapshot()
    #expect(state.transfers.map(\.id) == [item.id])
    #expect(state.transfers.first?.status == .delivered)
    #expect(state.cloudChangeToken == Data([42]))
    #expect(mailbox.receipts[item.id] != nil)
}

@Test func revocationDuringReceivePreventsPersistenceAndAcknowledgement() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try TransferRepository(directory: directory, keyData: Data(repeating: 1, count: 32))
    let peer = LocalIdentity(privateKey: Curve25519.KeyAgreement.PrivateKey())
    try await store.saveDevice(TrustedDevice(id: peer.id, name: "Phone", publicKey: peer.publicKey))
    let outbound = TransferItem(senderDeviceID: "local", receiverDeviceID: peer.id, kind: .text, title: "Outgoing", status: .sent)
    try await store.save(outbound)
    try await store.forgetDevice(peer.id)
    let incoming = TransferItem(senderDeviceID: peer.id, receiverDeviceID: "local", kind: .text, title: "Incoming", status: .delivered)
    await #expect(throws: TossError.untrustedDevice) { try await store.recordIncoming(incoming, requiringTrustedSender: true) }
    await #expect(throws: TossError.authenticationFailed) {
        try await store.applyReceipt(outbound.id, senderID: peer.id, localDeviceID: "local", accepted: true)
    }
    #expect(try await store.snapshot().transfers.count == 1)
    #expect(try await store.snapshot().transfers.first?.failure == .untrustedDevice)
}

@Test func missingFileHasDifferentRecoveryFromFullStorage() {
    #expect(DeliveryIssue(error: CocoaError(.fileReadNoSuchFile)) == .missingFile)
    #expect(DeliveryIssue(error: CocoaError(.fileWriteOutOfSpace)) == .storage)
    #expect(DeliveryIssue.missingFile.guidance.contains("fresh copy"))
}
