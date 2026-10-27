#if DEBUG
import CloudKit
import CryptoKit
import TossCore
import Foundation

/// UI tests never modify personal history, trust records, or the real remote mailbox.
@MainActor enum UITestFixtures {
    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains("--uitest-isolated") }

    static func makeEngine() async throws -> TossEngine? {
        guard isEnabled else { return nil }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TossUITests", isDirectory: true)
        // This fixed test-only directory contains no App Group or user data.
        try? FileManager.default.removeItem(at: directory)
        let repository = try TransferRepository(directory: directory, keyData: Data(repeating: 31, count: 32))
        let local = LocalIdentity(privateKey: Curve25519.KeyAgreement.PrivateKey())
        let peer = LocalIdentity(privateKey: Curve25519.KeyAgreement.PrivateKey())
        let engine = try TossEngine(identity: local, repository: repository, name: "Test iPhone", remoteTransport: OfflineMailbox())
        if ProcessInfo.processInfo.arguments.contains("--uitest-transfers") {
            try await repository.saveDevice(TrustedDevice(id: peer.id, name: "My MacBook", publicKey: peer.publicKey))
            var failed = TransferItem(senderDeviceID: local.id, receiverDeviceID: peer.id, kind: .text,
                title: "A note for my Mac", text: "A note for my Mac", byteCount: 17, status: .failed)
            failed.failure = .cloudStorage
            try await repository.save(failed)
            let missing = TransferItem(senderDeviceID: peer.id, receiverDeviceID: local.id, kind: .file,
                title: "Missing preview.pdf", filename: "Missing preview.pdf", typeIdentifier: "com.adobe.pdf",
                byteCount: 300, status: .delivered, blobID: UUID())
            _ = try await repository.recordIncoming(missing)
        }
        await engine.refresh()
        return engine
    }
}

@MainActor private final class OfflineMailbox: RemoteTransferTransport {
    func prepare() async throws -> String { throw CKError(.notAuthenticated) }
    func accountStatus() async throws -> CKAccountStatus { .noAccount }
    func uploadTransfer(_ envelope: SecureEnvelope, transferID: UUID) async throws { throw CKError(.notAuthenticated) }
    func uploadReceipt(_ envelope: SecureEnvelope, transferID: UUID) async throws { throw CKError(.notAuthenticated) }
    func changes(since encodedToken: Data?) async throws -> CloudChangePage { throw CKError(.notAuthenticated) }
    func existingTransfer(_ id: UUID) async throws -> SecureEnvelope { throw CKError(.unknownItem) }
    func existingReceipt(_ id: UUID) async throws -> SecureEnvelope { throw CKError(.unknownItem) }
    func deleteTransfer(_ id: UUID) async throws { throw CKError(.notAuthenticated) }
    func deleteReceipt(_ id: UUID) async throws { throw CKError(.notAuthenticated) }
}
#endif
