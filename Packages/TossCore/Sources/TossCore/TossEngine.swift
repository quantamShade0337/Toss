import Foundation
import Observation
import os
import CloudKit
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct TransferPayload: Codable, Sendable {
    let item: TransferItem
    let data: Data?

    func matchesContent(of other: Self) -> Bool {
        item.id == other.item.id && item.senderDeviceID == other.item.senderDeviceID &&
        item.receiverDeviceID == other.item.receiverDeviceID && item.createdAt == other.item.createdAt &&
        item.kind == other.item.kind && item.title == other.item.title && item.subtitle == other.item.subtitle &&
        item.text == other.item.text && item.sourceURL == other.item.sourceURL &&
        item.filename == other.item.filename && item.typeIdentifier == other.item.typeIdentifier &&
        item.byteCount == other.item.byteCount && item.scheduledAt == other.item.scheduledAt && data == other.data
    }
}

struct Receipt: Codable, Sendable {
    let transferID: UUID
    let accepted: Bool
}

public enum PairingProgress: Equatable, Sendable {
    case idle, connecting(String), connected(String), failed(String)
}

@MainActor @Observable
public final class TossEngine {
    private let logger = Logger(subsystem: "com.ethansoh.toss", category: "transfer")
    private let pairingLogger = Logger(subsystem: "com.ethansoh.toss", category: "pairing")
    private let nearbyLogger = Logger(subsystem: "com.ethansoh.toss", category: "nearby")
    private let cloudLogger = Logger(subsystem: "com.ethansoh.toss", category: "cloud")
    private let cryptoLogger = Logger(subsystem: "com.ethansoh.toss", category: "crypto")
    private let storageLogger = Logger(subsystem: "com.ethansoh.toss", category: "storage")
    public let identity: LocalIdentity
    public let repository: TransferRepository
    public let name: String
    public private(set) var devices: [TrustedDevice] = []
    public private(set) var transfers: [TransferItem] = []
    public private(set) var onlineIDs: Set<String> = []
    public private(set) var remoteAvailability: RemoteAvailability = .checking
    public private(set) var remoteIssue: DeliveryIssue?
    public private(set) var lastRemoteSync: Date?
    public private(set) var pairingProgress: PairingProgress = .idle
    public private(set) var pairingOffer: PairingOffer?
    public private(set) var pairingMessage: String?
    public var errorMessage: String?
    public var onIncoming: ((TransferItem) -> Void)?
    private let transport: PeerTransport
    @ObservationIgnored private lazy var cloud: any RemoteTransferTransport = remoteOverride ?? CloudTransferTransport()
    @ObservationIgnored private let remoteOverride: (any RemoteTransferTransport)?
    private var pendingOffer: PairingOffer?
    private var pairingTask: Task<Void, Never>?
    private var didRecover = false
    private var startupTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var isRunning = false
    private var isFlushing = false
    private var flushRequested = false
    private var isFlushingReceipts = false
    private var isSyncingRemote = false

    public init(identity: LocalIdentity? = nil, repository: TransferRepository? = nil,
                name: String? = nil, remoteTransport: (any RemoteTransferTransport)? = nil) throws {
        self.identity = try identity ?? LocalIdentity()
        self.repository = try repository ?? TransferRepository()
        self.remoteOverride = remoteTransport
        #if os(iOS)
        self.name = name ?? UIDevice.current.name
        #else
        self.name = name ?? Host.current().localizedName ?? "This Mac"
        #endif
        transport = PeerTransport(deviceID: self.identity.id, name: self.name)
        transport.onConnected = { [weak self] id in
            guard let self else { return }
            self.nearbyLogger.debug("Nearby session connected")
            self.onlineIDs.insert(id)
            if let offer = self.pendingOffer, offer.deviceID == id { self.sendPairingHello(offer) }
            Task { await self.flush(destination: id) }
        }
        transport.onDisconnected = { [weak self] id in
            self?.nearbyLogger.debug("Nearby session disconnected")
            self?.onlineIDs.remove(id)
        }
        transport.onMessage = { [weak self] message, id in
            Task { await self?.receive(message, from: id) }
        }
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        startupTask = Task {
            if !didRecover {
                do {
                    try await repository.recoverInterruptedSends(localDeviceID: identity.id)
                    didRecover = true
                }
                catch { errorMessage = DeliveryIssue.storage.guidance }
            }
            let days = UserDefaults.standard.integer(forKey: "history-retention-days")
            if days > 0 {
                try? await repository.pruneHistory(olderThan: Date.now.addingTimeInterval(-Double(days) * 86_400))
            }
            await refresh()
            guard !Task.isCancelled, isRunning else { return }
            transport.start()
            await syncRemote()
            await flush()
        }
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, !Task.isCancelled else { return }
                await self.refresh()
                await self.syncRemote()
                await self.flush()
            }
        }
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        retryTask?.cancel()
        startupTask?.cancel()
        transport.stop()
        onlineIDs.removeAll()
    }

    public func refresh() async {
        do {
            let state = try await repository.snapshot()
            devices = state.devices.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            transfers = state.transfers.sorted { $0.createdAt > $1.createdAt }
            transport.trustedIDs = Set(state.devices.map(\.id))
        } catch {
            storageLogger.error("Unable to refresh encrypted state")
            errorMessage = DeliveryIssue(error: error).guidance
        }
    }

    @discardableResult
    public func sendText(_ text: String, to deviceID: String, scheduledAt: Date? = nil) async throws -> TransferItem {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 1_000_000 else { throw TossError.invalidContent }
        let classification = await Task.detached(priority: .userInitiated) {
            ContentClassifier.classify(trimmed)
        }.value
        let item = TransferItem(senderDeviceID: identity.id, receiverDeviceID: deviceID,
                                kind: classification.kind, title: classification.title,
                                subtitle: classification.subtitle, text: trimmed,
                                sourceURL: classification.sourceURL, byteCount: trimmed.utf8.count,
                                scheduledAt: scheduledAt)
        try await enqueue(item)
        return item
    }

    @discardableResult
    public func sendFile(_ url: URL, to deviceID: String, scheduledAt: Date? = nil) async throws -> TransferItem {
        let data = try await Task.detached(priority: .userInitiated) {
            try FileSafety.load(url)
        }.value
        let type = UTType(filenameExtension: url.pathExtension)
        return try await sendData(data, filename: url.lastPathComponent, typeIdentifier: type?.identifier,
                                  to: deviceID, scheduledAt: scheduledAt)
    }

    @discardableResult
    public func sendData(_ data: Data, filename: String, typeIdentifier: String?,
                         to deviceID: String, scheduledAt: Date? = nil) async throws -> TransferItem {
        try await Task.detached(priority: .userInitiated) {
            try FileSafety.validate(data, typeIdentifier: typeIdentifier)
        }.value
        guard try await repository.device(deviceID) != nil else { throw TossError.untrustedDevice }
        let blobID = try await repository.storeBlob(data)
        let safeName = FileSafety.safeFilename(filename)
        let kind: ContentKind = UTType(typeIdentifier ?? "")?.conforms(to: .image) == true ? .image : .file
        let item = TransferItem(senderDeviceID: identity.id, receiverDeviceID: deviceID,
                                kind: kind, title: safeName, subtitle: ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file),
                                filename: safeName, typeIdentifier: typeIdentifier, byteCount: data.count,
                                scheduledAt: scheduledAt, blobID: blobID)
        do { try await enqueue(item) }
        catch { await repository.removeBlob(blobID); throw error }
        return item
    }

    public func resend(_ item: TransferItem, to deviceID: String) async throws {
        if let blobID = item.blobID {
            let data = try await repository.loadBlob(blobID)
            _ = try await sendData(data, filename: item.filename ?? item.title,
                                   typeIdentifier: item.typeIdentifier, to: deviceID)
        } else if let text = item.text {
            _ = try await sendText(text, to: deviceID)
        }
    }

    public func saveLocally(text: String) async throws {
        guard !text.isEmpty, text.utf8.count <= 1_000_000 else { throw TossError.invalidContent }
        let content = await Task.detached(priority: .userInitiated) {
            ContentClassifier.classify(text)
        }.value
        var item = TransferItem(senderDeviceID: identity.id, receiverDeviceID: identity.id,
                                kind: content.kind, title: content.title, subtitle: content.subtitle,
                                text: text, sourceURL: content.sourceURL, byteCount: text.utf8.count,
                                status: .delivered, isRead: true, isArchived: true)
        item.completedAt = .now
        try await repository.save(item)
        await refresh()
    }

    public func saveLocally(data: Data, filename: String, typeIdentifier: String?) async throws {
        try await Task.detached(priority: .userInitiated) {
            try FileSafety.validate(data, typeIdentifier: typeIdentifier)
        }.value
        let blobID = try await repository.storeBlob(data)
        var item = TransferItem(senderDeviceID: identity.id, receiverDeviceID: identity.id,
                                kind: UTType(typeIdentifier ?? "")?.conforms(to: .image) == true ? .image : .file,
                                title: FileSafety.safeFilename(filename), subtitle: "Saved for later",
                                filename: FileSafety.safeFilename(filename), typeIdentifier: typeIdentifier,
                                byteCount: data.count, status: .delivered, isRead: true, isArchived: true,
                                blobID: blobID)
        item.completedAt = .now
        do { try await repository.save(item) }
        catch { await repository.removeBlob(blobID); throw error }
        await refresh()
    }

    private func enqueue(_ item: TransferItem) async throws {
        guard try await repository.device(item.receiverDeviceID) != nil else { throw TossError.untrustedDevice }
        try await repository.save(item)
        await refresh()
        Task { await self.flush(destination: item.receiverDeviceID) }
    }

    public func flush(destination: String? = nil) async {
        guard !isFlushing else { flushRequested = true; return }
        isFlushing = true
        defer {
            isFlushing = false
            if flushRequested {
                flushRequested = false
                Task { await self.flush() }
            }
        }
        let state: TossState
        do { state = try await repository.snapshot() }
        catch { errorMessage = DeliveryIssue(error: error).guidance; return }
        for item in state.transfers where item.senderDeviceID == identity.id
            && (item.status == .queued || item.status == .sent)
            && (destination == nil || item.receiverDeviceID == destination) {
            do {
                if max(item.createdAt, item.scheduledAt ?? item.createdAt) < Date.now.addingTimeInterval(-30 * 86_400) {
                    try await repository.recordFailure(item.id, issue: .expired, terminal: true)
                    continue
                }
                switch TransferCoordinator.route(for: item,
                    trusted: state.devices.contains { $0.id == item.receiverDeviceID },
                    nearbyConnected: transport.connectedIDs.contains(item.receiverDeviceID),
                    remoteAvailable: remoteAvailability == .available) {
                case .nearby:
                    try await sendQueued(item, devices: state.devices)
                case .remote:
                    try await sendRemote(item, devices: state.devices)
                case .queued: break
                case .reject: throw TossError.untrustedDevice
                }
            }
            catch {
                let permanent = Self.isPermanentSendFailure(error)
                let issue = DeliveryIssue(error: error)
                try? await repository.recordFailure(item.id, issue: issue, terminal: permanent)
                if error is CKError { remoteIssue = issue }
                logger.error("Send failed (permanent: \(permanent, privacy: .public))")
            }
            await refresh()
        }
        await flushReceipts()
        await cleanExpiredCloudLeases()
        await refresh()
    }

    private static func isPermanentSendFailure(_ error: Error) -> Bool {
        if let toss = error as? TossError {
            return [.tooLarge, .invalidContent, .authenticationFailed, .corruptData, .untrustedDevice].contains(toss)
        }
        if let cloud = error as? CKError {
            return [.quotaExceeded, .permissionFailure, .badContainer, .missingEntitlement].contains(cloud.code)
        }
        return false
    }

    private func sendQueued(_ item: TransferItem, devices: [TrustedDevice]) async throws {
        guard let device = devices.first(where: { $0.id == item.receiverDeviceID }) else { throw TossError.untrustedDevice }
        if item.status == .queued {
            try await repository.updateStatus(item.id, to: .discovering)
            try await repository.updateStatus(item.id, to: .sending)
        }
        await refresh()
        let sealed = try await sealedTransfer(item, to: device)
        guard try await repository.device(device.id) != nil else { throw TossError.untrustedDevice }
        try transport.send(.transfer(sealed), to: device.id)
        if item.status != .sent {
            try await repository.updateStatus(item.id, to: .sent)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                await self?.flush(destination: device.id)
            }
        }
    }

    private func sealedTransfer(_ item: TransferItem, to device: TrustedDevice) async throws -> SecureEnvelope {
        let data: Data?
        if let blobID = item.blobID { data = try await repository.loadBlob(blobID) }
        else { data = nil }
        let local = identity
        return try await Task.detached(priority: .userInitiated) {
            try CryptoBox.seal(PropertyListEncoder().encode(TransferPayload(item: item, data: data)),
                               from: local, to: device)
        }.value
    }

    private func sendRemote(_ item: TransferItem, devices: [TrustedDevice]) async throws {
        guard let device = devices.first(where: { $0.id == item.receiverDeviceID }) else { throw TossError.untrustedDevice }
        try await repository.updateStatus(item.id, to: .sending)
        await refresh()
        let sealed = try await sealedTransfer(item, to: device)
        do { try await cloud.uploadTransfer(sealed, transferID: item.id) }
        catch let error as CKError where error.code == .serverRecordChanged {
            let existing = try await cloud.existingTransfer(item.id)
            let local = identity
            try await Task.detached(priority: .userInitiated) {
                let previous = try PropertyListDecoder().decode(TransferPayload.self,
                    from: CryptoBox.openSent(existing, local: local, to: device))
                let proposed = try PropertyListDecoder().decode(TransferPayload.self,
                    from: CryptoBox.openSent(sealed, local: local, to: device))
                guard previous.matchesContent(of: proposed) else { throw TossError.authenticationFailed }
            }.value
        }
        let committed = try await repository.completeRemoteUpload(item.id, recipientID: device.id,
                                                                  expiresAt: .now.addingTimeInterval(30 * 86_400))
        if !committed {
            await cleanExpiredCloudLeases()
            throw TossError.untrustedDevice
        }
    }

    public func retry(_ item: TransferItem) async {
        guard item.senderDeviceID == identity.id, item.receiverDeviceID != identity.id,
              [.failed, .queued].contains(item.status) else { return }
        do {
            if item.failure == .declined || item.failure == .expired {
                try await resend(item, to: item.receiverDeviceID)
            } else {
                try await repository.updateStatus(item.id, to: .queued)
                await syncRemote()
                await flush(destination: item.receiverDeviceID)
            }
        } catch { errorMessage = DeliveryIssue(error: error).guidance }
    }

    public func markRead(_ item: TransferItem) async {
        do { try await repository.markRead(item.id) }
        catch { errorMessage = DeliveryIssue(error: error).guidance }
        await refresh()
    }

    public func archive(_ item: TransferItem, _ archived: Bool = true) async {
        do { try await repository.setArchived(item.id, archived) }
        catch { errorMessage = DeliveryIssue(error: error).guidance }
        await refresh()
    }

    @discardableResult
    public func delete(_ item: TransferItem) async -> Bool {
        if item.receiverDeviceID == identity.id, item.status == .queued {
            return await decline(item)
        }
        do {
            if item.senderDeviceID == identity.id && item.status != .delivered {
                try await repository.queueCloudDeletions([item.id])
            }
            try await repository.delete(item.id)
            await cleanExpiredCloudLeases()
        }
        catch { errorMessage = DeliveryIssue(error: error).guidance; return false }
        await refresh()
        return true
    }

    public func clearHistory() async {
        do {
            let state = try await repository.snapshot()
            for item in state.transfers where item.receiverDeviceID == identity.id && item.status == .queued {
                try await repository.queueReceipt(PendingReceipt(transferID: item.id,
                                                                 senderID: item.senderDeviceID,
                                                                 accepted: false))
            }
            let outboundPending = Set(state.transfers.filter {
                $0.senderDeviceID == identity.id && $0.status != .delivered
            }.map(\.id))
            try await repository.queueCloudDeletions(outboundPending)
            try await repository.clearHistory()
            await flushReceipts()
            await cleanExpiredCloudLeases()
            await refresh()
        }
        catch { errorMessage = DeliveryIssue(error: error).guidance }
    }

    public func applyRetention(days: Int) async {
        guard days > 0 else { return }
        do {
            try await repository.pruneHistory(olderThan: Date.now.addingTimeInterval(-Double(days) * 86_400))
            await refresh()
        } catch { errorMessage = DeliveryIssue(error: error).guidance }
    }

    @discardableResult
    public func forget(_ device: TrustedDevice) async -> Bool {
        do { try await repository.forgetDevice(device.id) }
        catch { errorMessage = DeliveryIssue(error: error).guidance; return false }
        await cleanExpiredCloudLeases()
        await refresh()
        return true
    }

    @discardableResult
    public func updateDevice(_ device: TrustedDevice) async -> Bool {
        var safe = device
        safe.name = String(device.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        if safe.name.isEmpty { safe.name = "My device" }
        do { try await repository.saveDevice(safe) }
        catch { errorMessage = DeliveryIssue(error: error).guidance; return false }
        await refresh()
        return true
    }

    @discardableResult
    public func approve(_ item: TransferItem) async -> Bool {
        guard item.receiverDeviceID == identity.id, item.status == .queued else { return false }
        do {
            try await repository.updateStatus(item.id, to: .delivered)
            await refresh()
            try await repository.queueReceipt(PendingReceipt(transferID: item.id, senderID: item.senderDeviceID, accepted: true))
            await flushReceipts()
        } catch { errorMessage = DeliveryIssue(error: error).guidance; return false }
        return true
    }

    @discardableResult
    public func decline(_ item: TransferItem) async -> Bool {
        guard item.receiverDeviceID == identity.id, item.status == .queued else { return false }
        do {
            try await repository.rejectIncoming(item.id)
            await refresh()
            try await repository.queueReceipt(PendingReceipt(transferID: item.id, senderID: item.senderDeviceID, accepted: false))
            await flushReceipts()
        } catch { errorMessage = DeliveryIssue(error: error).guidance; return false }
        return true
    }

    public func cancelPairing() {
        pairingTask?.cancel()
        pairingTask = nil
        pendingOffer = nil
        pairingOffer = nil
        transport.pairingDeadline = nil
        pairingProgress = .idle
        pairingMessage = nil
    }

    public func createPairingOffer() throws {
        cancelPairing()
        let secret = try SecureRandom.bytes(count: 32)
        pairingOffer = PairingOffer(identity: identity, deviceName: name, secret: secret,
                                    expiresAt: .now.addingTimeInterval(300))
        transport.pairingDeadline = pairingOffer?.expiresAt
        pairingMessage = nil
    }

    public func pair(using url: URL) throws {
        let offer = try PairingOffer(url: url)
        guard offer.deviceID != identity.id else { throw TossError.invalidPairingCode }
        cancelPairing()
        pendingOffer = offer
        pairingProgress = .connecting(offer.deviceName)
        transport.pairingDeadline = offer.expiresAt
        pairingMessage = "Connecting to \(offer.deviceName)…"
        if transport.connectedIDs.contains(offer.deviceID) { sendPairingHello(offer) }
        pairingTask = Task { [weak self] in
            for _ in 0..<15 {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self, self.pendingOffer != nil else { return }
                if self.transport.connectedIDs.contains(offer.deviceID) { self.sendPairingHello(offer) }
            }
            guard let self, self.pendingOffer != nil else { return }
            self.pendingOffer = nil
            self.transport.pairingDeadline = nil
            self.pairingProgress = .failed("Keep both devices nearby with Toss open. Turn on Wi-Fi and Bluetooth, and allow Local Network access in Settings. Then scan a new code.")
        }
    }

    private func sendPairingHello(_ offer: PairingOffer) {
        let hello = PairingHello(identity: identity, deviceName: name, offer: offer)
        do { try transport.send(.pairingHello(hello), to: offer.deviceID) }
        catch { pairingMessage = "Waiting for \(offer.deviceName) to come online…" }
    }

    private func receive(_ message: WireMessage, from discoveredID: String) async {
        do {
            switch message {
            case .pairingHello(let hello):
                guard let offer = pairingOffer, hello.deviceID == discoveredID,
                      hello.verify(offer: offer) else { throw TossError.authenticationFailed }
                let device = TrustedDevice(id: hello.deviceID, name: hello.deviceName, publicKey: hello.publicKey)
                try await repository.saveDevice(device)
                let ack = try CryptoBox.seal(Data("pair-ok".utf8), from: identity, to: device)
                try transport.send(.pairingAck(ack), to: device.id)
                pairingOffer = nil
                transport.pairingDeadline = nil
                pairingTask?.cancel()
                pairingProgress = .connected(device.name)
                pairingMessage = "Connected to \(device.name)"
                pairingLogger.info("Pairing completed")
                await refresh()
                await flush(destination: device.id)
            case .pairingAck(let envelope):
                guard let offer = pendingOffer, offer.deviceID == discoveredID else { throw TossError.authenticationFailed }
                let device = TrustedDevice(id: offer.deviceID, name: offer.deviceName, publicKey: offer.publicKey)
                let opened = try CryptoBox.open(envelope, local: identity, from: device)
                guard opened == Data("pair-ok".utf8) else { throw TossError.authenticationFailed }
                try await repository.saveDevice(device)
                pendingOffer = nil
                transport.pairingDeadline = nil
                pairingTask?.cancel()
                pairingProgress = .connected(device.name)
                pairingMessage = "Connected to \(device.name)"
                pairingLogger.info("Pairing completed")
                await refresh()
                await flush(destination: device.id)
            case .transfer(let envelope):
                guard let device = try await repository.device(discoveredID) else { throw TossError.untrustedDevice }
                try await processTransfer(envelope, from: device)
            case .receipt(let envelope):
                guard let device = try await repository.device(discoveredID) else { throw TossError.untrustedDevice }
                try await processReceipt(envelope, from: device, expectedAccepted: true)
            case .rejection(let envelope):
                guard let device = try await repository.device(discoveredID) else { throw TossError.untrustedDevice }
                try await processReceipt(envelope, from: device, expectedAccepted: false)
            }
        } catch {
            cryptoLogger.error("Rejected incoming message")
        }
    }

    private func processTransfer(_ envelope: SecureEnvelope, from device: TrustedDevice,
                                 expectedID: UUID? = nil) async throws {
        let local = identity
        let payload = try await Task.detached(priority: .userInitiated) {
            let plaintext: Data
            do { plaintext = try CryptoBox.open(envelope, local: local, from: device) }
            catch { throw TossError.authenticationFailed }
            guard plaintext.count <= FileSafety.maximumBytes + 100_000 else { throw TossError.tooLarge }
            let payload: TransferPayload
            do { payload = try PropertyListDecoder().decode(TransferPayload.self, from: plaintext) }
            catch { throw TossError.corruptData }
            if let expectedID, payload.item.id != expectedID { throw TossError.authenticationFailed }
            try IncomingValidator.validate(payload.item, data: payload.data,
                                           senderID: device.id, receiverID: local.id)
            return payload
        }.value
        let priorState = try await repository.snapshot()
        if !priorState.receivedIDs.contains(payload.item.id) {
            var item = payload.item
            item.status = device.autoAccept ? .delivered : .queued
            item.completedAt = device.autoAccept ? .now : nil
            item.isRead = false
            item.isArchived = false
            item.filename = item.filename.map(FileSafety.safeFilename)
            if let data = payload.data { item.blobID = try await repository.storeBlob(data) }
            else { item.blobID = nil }
            do {
                if try await repository.recordIncoming(item, requiringTrustedSender: true) {
                    await refresh()
                    onIncoming?(item)
                } else if let blobID = item.blobID { await repository.removeBlob(blobID) }
            } catch {
                if let blobID = item.blobID { await repository.removeBlob(blobID) }
                throw error
            }
        }
        if let accepted = try await repository.receiptDecision(for: payload.item.id) {
            try await repository.queueReceipt(PendingReceipt(transferID: payload.item.id, senderID: device.id, accepted: accepted))
        }
        await flushReceipts()
    }

    private func processReceipt(_ envelope: SecureEnvelope, from device: TrustedDevice,
                                expectedAccepted: Bool? = nil, expectedID: UUID? = nil) async throws {
        let local = identity
        let receipt = try await Task.detached(priority: .userInitiated) {
            do {
                let plaintext = try CryptoBox.open(envelope, local: local, from: device)
                return try PropertyListDecoder().decode(Receipt.self, from: plaintext)
            } catch { throw TossError.authenticationFailed }
        }.value
        if let expectedAccepted, receipt.accepted != expectedAccepted { throw TossError.authenticationFailed }
        if let expectedID, receipt.transferID != expectedID { throw TossError.authenticationFailed }
        try await repository.applyReceipt(receipt.transferID, senderID: device.id, localDeviceID: identity.id, accepted: receipt.accepted)
        await refresh()
    }

    public func syncRemote() async {
        guard !isSyncingRemote else { return }
        isSyncingRemote = true
        defer { isSyncingRemote = false }
        do {
            let accountID = try await cloud.prepare()
            try await repository.bindCloudAccount(accountID, localDeviceID: identity.id)
            remoteAvailability = .available
            remoteIssue = nil
            var moreComing = true
            while moreComing {
                let state = try await repository.snapshot()
                let page: CloudChangePage
                do { page = try await cloud.changes(since: state.cloudChangeToken) }
                catch let error as CKError where error.code == .changeTokenExpired {
                    try await repository.saveCloudChangeToken(nil)
                    continue
                }
                for record in page.records {
                    try await processCloudRecord(record)
                }
                try await repository.saveCloudChangeToken(page.token)
                moreComing = page.moreComing
            }
            lastRemoteSync = .now
            cloudLogger.debug("Remote sync completed")
            await flushReceipts()
            await flush()
        } catch {
            if let cloudError = error as? CKError,
               [.notAuthenticated, .permissionFailure, .badContainer, .missingEntitlement].contains(cloudError.code) {
                remoteAvailability = .unavailable
            } else if (try? await cloud.accountStatus()) != .available {
                remoteAvailability = .unavailable
            }
            remoteIssue = DeliveryIssue(error: error)
            if remoteAvailability == .checking { remoteAvailability = .unavailable }
            cloudLogger.error("Remote sync unavailable")
        }
    }

    private func processCloudRecord(_ record: CKRecord) async throws {
        guard let recipient = record["recipient"] as? String, recipient == identity.id else { return }
        guard let senderID = record["sender"] as? String,
              let sender = try await repository.device(senderID) else { return }
        do {
            let envelope = try await Task.detached(priority: .userInitiated) {
                try CloudTransferTransport.decodeEnvelope(from: record)
            }.value
            if record.recordType == CloudTransferTransport.transferType {
                guard let id = UUID(uuidString: String(record.recordID.recordName.dropFirst("transfer-".count))) else { return }
                try await processTransfer(envelope, from: sender, expectedID: id)
            } else if record.recordType == CloudTransferTransport.receiptType {
                guard let id = UUID(uuidString: String(record.recordID.recordName.dropFirst("receipt-".count))) else { return }
                try await processReceipt(envelope, from: sender, expectedID: id)
                try? await cloud.deleteReceipt(id)
                try? await cloud.deleteTransfer(id)
                try? await repository.clearCloudLease(id)
            }
        } catch let error as TossError {
            if error == .storageUnavailable { throw error }
            logger.error("Rejected remote record: \(error.localizedDescription, privacy: .public)")
        } catch {
            // Keep the token unchanged on transient local failures so this record is retried.
            throw error
        }
    }

    private func flushReceipts() async {
        guard !isFlushingReceipts else { return }
        isFlushingReceipts = true
        defer { isFlushingReceipts = false }
        guard let state = try? await repository.snapshot() else { return }
        for receipt in state.pendingReceipts {
            guard let device = state.devices.first(where: { $0.id == receipt.senderID }) else { continue }
            guard let data = try? PropertyListEncoder().encode(Receipt(transferID: receipt.transferID,
                                                                        accepted: receipt.accepted)),
                  let envelope = try? CryptoBox.seal(data, from: identity, to: device) else { continue }
            if transport.connectedIDs.contains(device.id) {
                try? transport.send(receipt.accepted ? .receipt(envelope) : .rejection(envelope), to: device.id)
            }
            if remoteAvailability == .available {
                do {
                    try await cloud.uploadReceipt(envelope, transferID: receipt.transferID)
                    try await repository.completeReceipt(receipt.transferID)
                    try? await cloud.deleteTransfer(receipt.transferID)
                } catch let error as CKError where error.code == .serverRecordChanged {
                    if let existing = try? await cloud.existingReceipt(receipt.transferID),
                       let opened = try? CryptoBox.openSent(existing, local: identity, to: device),
                       let previous = try? PropertyListDecoder().decode(Receipt.self, from: opened),
                       previous.transferID == receipt.transferID,
                       previous.accepted == receipt.accepted {
                        try? await repository.completeReceipt(receipt.transferID)
                        try? await cloud.deleteTransfer(receipt.transferID)
                    }
                } catch {
                    logger.error("Receipt upload will retry")
                }
            }
        }
    }

    private func cleanExpiredCloudLeases() async {
        guard remoteAvailability == .available,
              let state = try? await repository.snapshot() else { return }
        let due = state.cloudPendingDeletion.union(state.cloudLeases.compactMap { id, expiry in
            expiry < .now ? id : nil
        })
        for id in due {
            if let expiry = state.cloudLeases[id], expiry < .now {
                try? await repository.recordFailure(id, issue: .expired, terminal: true)
            }
            do {
                try await cloud.deleteTransfer(id)
                try await repository.clearCloudLease(id)
            } catch let error as CKError where error.code == .unknownItem {
                try? await repository.clearCloudLease(id)
            } catch { continue }
        }
    }

}
