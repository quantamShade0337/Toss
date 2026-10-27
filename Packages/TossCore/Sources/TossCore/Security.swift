import CryptoKit
import Foundation
import Security

// Security model: a QR code authenticates a device's static X25519 public key and a short-lived
// one-time pairing secret. The private key never leaves Keychain. Every transfer uses a fresh HKDF
// salt and AES-GCM; the protocol version, message ID, and both device IDs are authenticated data.
// Multipeer discovery labels are only routing hints and never establish trust.

public enum SecureRandom {
    public static func bytes(count: Int) throws -> Data {
        guard count > 0 else { throw TossError.invalidContent }
        var data = Data(count: count)
        let result = data.withUnsafeMutableBytes { bytes in
            guard let address = bytes.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, count, address)
        }
        guard result == errSecSuccess else { throw TossError.authenticationFailed }
        return data
    }
}

public enum KeychainVault {
    private static let service = "com.ethansoh.toss.keys"

    private static var accessGroup: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "TossKeychainAccessGroup") as? String,
              !value.isEmpty, !value.contains("$(") else { return nil }
        return value
    }

    private static func query(for account: String, shared: Bool) throws -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if shared {
            guard let accessGroup else { throw TossError.storageUnavailable }
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    private static func read(account: String, shared: Bool) throws -> Data? {
        var request = try query(for: account, shared: shared)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw TossError.storageUnavailable }
        return data
    }

    public static func data(for account: String) throws -> Data? {
        try read(account: account, shared: true)
    }

    public static func getOrCreate(account: String, count: Int) throws -> Data {
        if let existing = try data(for: account) { return existing }
        // Only the containing app migrates an old, app-private key. Extensions wait for it,
        // preventing a first extension launch from replacing an existing installation identity.
        let isExtension = Bundle.main.bundleURL.pathExtension == "appex"
        if isExtension { throw TossError.storageUnavailable }
        let value = try read(account: account, shared: false) ?? SecureRandom.bytes(count: count)
        var query = try query(for: account, shared: true)
        query[kSecValueData as String] = value
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem, let existing = try data(for: account) { return existing }
        guard status == errSecSuccess else { throw TossError.storageUnavailable }
        return value
    }
}

public struct LocalIdentity: Sendable {
    public let privateKey: Curve25519.KeyAgreement.PrivateKey
    public let publicKey: Data
    public let id: String

    public init() throws {
        let raw = try KeychainVault.getOrCreate(account: "identity-v1", count: 32)
        privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw)
        publicKey = privateKey.publicKey.rawRepresentation
        id = Self.fingerprint(publicKey)
    }

    public init(privateKey: Curve25519.KeyAgreement.PrivateKey) {
        self.privateKey = privateKey
        publicKey = privateKey.publicKey.rawRepresentation
        id = Self.fingerprint(publicKey)
    }

    public static func fingerprint(_ key: Data) -> String {
        SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined()
    }

    public static func verificationCode(_ key: Data) -> String {
        let prefix = String(fingerprint(key).prefix(12)).uppercased()
        return stride(from: 0, to: prefix.count, by: 4).map {
            let start = prefix.index(prefix.startIndex, offsetBy: $0)
            let end = prefix.index(start, offsetBy: min(4, prefix.count - $0))
            return String(prefix[start..<end])
        }.joined(separator: " ")
    }
}

public struct SecureEnvelope: Codable, Sendable {
    public let version: Int
    public let id: UUID
    public let senderID: String
    public let receiverID: String
    public let salt: Data
    public let sealed: Data

    public init(version: Int = 1, id: UUID = UUID(), senderID: String, receiverID: String, salt: Data, sealed: Data) {
        self.version = version
        self.id = id
        self.senderID = senderID
        self.receiverID = receiverID
        self.salt = salt
        self.sealed = sealed
    }

    public var authenticatedHeader: Data {
        Data("toss-v\(version)|\(id.uuidString)|\(senderID)|\(receiverID)".utf8)
    }
}

public enum CryptoBox {
    public static func seal(_ data: Data, from local: LocalIdentity, to peer: TrustedDevice) throws -> SecureEnvelope {
        guard peer.id == LocalIdentity.fingerprint(peer.publicKey) else { throw TossError.authenticationFailed }
        let salt = try SecureRandom.bytes(count: 32)
        let header = SecureEnvelope(senderID: local.id, receiverID: peer.id, salt: salt, sealed: Data())
        let key = try sharedKey(local: local, publicKey: peer.publicKey, salt: salt)
        let sealed = try AES.GCM.seal(data, using: key, authenticating: header.authenticatedHeader)
        guard let combined = sealed.combined else { throw TossError.authenticationFailed }
        return SecureEnvelope(id: header.id, senderID: local.id, receiverID: peer.id, salt: salt, sealed: combined)
    }

    public static func open(_ envelope: SecureEnvelope, local: LocalIdentity, from peer: TrustedDevice) throws -> Data {
        guard envelope.version == 1, envelope.receiverID == local.id,
              envelope.senderID == peer.id, peer.id == LocalIdentity.fingerprint(peer.publicKey),
              envelope.salt.count == 32 else { throw TossError.authenticationFailed }
        let key = try sharedKey(local: local, publicKey: peer.publicKey, salt: envelope.salt)
        let box = try AES.GCM.SealedBox(combined: envelope.sealed)
        return try AES.GCM.open(box, using: key, authenticating: envelope.authenticatedHeader)
    }

    /// Used only to verify an idempotent upload already saved by this sender.
    /// Incoming messages must continue to use `open`, which enforces the opposite route.
    public static func openSent(_ envelope: SecureEnvelope, local: LocalIdentity, to peer: TrustedDevice) throws -> Data {
        guard envelope.version == 1, envelope.senderID == local.id,
              envelope.receiverID == peer.id, peer.id == LocalIdentity.fingerprint(peer.publicKey),
              envelope.salt.count == 32 else { throw TossError.authenticationFailed }
        let key = try sharedKey(local: local, publicKey: peer.publicKey, salt: envelope.salt)
        let box = try AES.GCM.SealedBox(combined: envelope.sealed)
        return try AES.GCM.open(box, using: key, authenticating: envelope.authenticatedHeader)
    }

    private static func sharedKey(local: LocalIdentity, publicKey: Data, salt: Data) throws -> SymmetricKey {
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey)
        let secret = try local.privateKey.sharedSecretFromKeyAgreement(with: peer)
        return secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt,
                                               sharedInfo: Data("Toss transfer v1".utf8), outputByteCount: 32)
    }
}

public struct PairingOffer: Codable, Sendable {
    public let deviceID: String
    public let deviceName: String
    public let publicKey: Data
    public let secret: Data
    public let expiresAt: Date
    public var verificationCode: String { LocalIdentity.verificationCode(publicKey) }

    public init(identity: LocalIdentity, deviceName: String, secret: Data, expiresAt: Date) {
        self.deviceID = identity.id
        self.deviceName = String(deviceName.prefix(100))
        self.publicKey = identity.publicKey
        self.secret = secret
        self.expiresAt = expiresAt
    }

    public var url: URL? {
        var components = URLComponents()
        components.scheme = "toss"
        components.host = "pair"
        components.queryItems = [URLQueryItem(name: "v", value: "1"),
                                 URLQueryItem(name: "k", value: publicKey.base64EncodedString()),
                                 URLQueryItem(name: "s", value: secret.base64EncodedString()),
                                 URLQueryItem(name: "n", value: deviceName),
                                 URLQueryItem(name: "e", value: String(Int(expiresAt.timeIntervalSince1970)))]
        return components.url
    }

    public init(url: URL) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "toss", components.host == "pair" else { throw TossError.invalidPairingCode }
        var fields: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard let value = item.value, fields[item.name] == nil else { throw TossError.invalidPairingCode }
            fields[item.name] = value
        }
        guard fields["v"] == "1", let keyString = fields["k"], let key = Data(base64Encoded: keyString),
              key.count == 32, let secretString = fields["s"], let secret = Data(base64Encoded: secretString),
              secret.count == 32, let name = fields["n"], name.count <= 100,
              let timeString = fields["e"], let time = TimeInterval(timeString) else { throw TossError.invalidPairingCode }
        let expiry = Date(timeIntervalSince1970: time)
        guard expiry > .now, expiry < Date.now.addingTimeInterval(600) else { throw TossError.pairingExpired }
        _ = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: key)
        publicKey = key
        deviceID = LocalIdentity.fingerprint(key)
        deviceName = name
        self.secret = secret
        expiresAt = expiry
    }
}

public struct PairingHello: Codable, Sendable {
    public let deviceID: String
    public let deviceName: String
    public let publicKey: Data
    public let offerDeviceID: String
    public let authenticator: Data

    public init(identity: LocalIdentity, deviceName: String, offer: PairingOffer) {
        self.deviceID = identity.id
        self.deviceName = String(deviceName.prefix(100))
        self.publicKey = identity.publicKey
        self.offerDeviceID = offer.deviceID
        let message = Self.message(deviceID: identity.id, publicKey: identity.publicKey, offerDeviceID: offer.deviceID)
        authenticator = Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: offer.secret)))
    }

    public func verify(offer: PairingOffer) -> Bool {
        guard deviceID == LocalIdentity.fingerprint(publicKey), offerDeviceID == offer.deviceID,
              deviceName.count <= 100, offer.expiresAt > .now else { return false }
        let message = Self.message(deviceID: deviceID, publicKey: publicKey, offerDeviceID: offerDeviceID)
        return HMAC<SHA256>.isValidAuthenticationCode(authenticator, authenticating: message,
                                                     using: SymmetricKey(data: offer.secret))
    }

    private static func message(deviceID: String, publicKey: Data, offerDeviceID: String) -> Data {
        Data("Toss pair v1|\(deviceID)|\(publicKey.base64EncodedString())|\(offerDeviceID)".utf8)
    }
}
