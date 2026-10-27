import Foundation
import MultipeerConnectivity

public enum WireMessage: Codable {
    case pairingHello(PairingHello)
    case pairingAck(SecureEnvelope)
    case transfer(SecureEnvelope)
    case receipt(SecureEnvelope)
    case rejection(SecureEnvelope)
}

@MainActor
public final class PeerTransport: NSObject {
    // Nearby discovery is unauthenticated. The engine checks every received message against its
    // QR-paired public-key store, and unpaired peers may send only small pairing frames.
    private static let serviceType = "toss-xfer"
    private let identityID: String
    private let peerID: MCPeerID
    private let session: MCSession
    private let advertiser: MCNearbyServiceAdvertiser
    private let browser: MCNearbyServiceBrowser
    private var peersByID: [String: MCPeerID] = [:]
    private var idsByPeer: [MCPeerID: String] = [:]
    private var invitedIDs: Set<String> = []
    public var onConnected: ((String) -> Void)?
    public var onDisconnected: ((String) -> Void)?
    public var onMessage: ((WireMessage, String) -> Void)?
    public private(set) var connectedIDs: Set<String> = []
    public var trustedIDs: Set<String> = [] { didSet { connectEligiblePeers() } }
    public var pairingDeadline: Date? { didSet { connectEligiblePeers() } }

    private var pairingAllowed: Bool { pairingDeadline.map { $0 > .now } ?? false }

    public init(deviceID: String, name: String) {
        identityID = deviceID
        peerID = MCPeerID(displayName: String(deviceID.prefix(24)))
        session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        advertiser = MCNearbyServiceAdvertiser(peer: peerID,
                                               discoveryInfo: ["id": deviceID, "name": String(name.prefix(50))],
                                               serviceType: Self.serviceType)
        browser = MCNearbyServiceBrowser(peer: peerID, serviceType: Self.serviceType)
        super.init()
        session.delegate = self
        advertiser.delegate = self
        browser.delegate = self
    }

    public func start() {
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
    }

    public func stop() {
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        session.disconnect()
        connectedIDs.removeAll()
        invitedIDs.removeAll()
    }

    public func send(_ message: WireMessage, to id: String) throws {
        guard connectedIDs.contains(id), let peer = peersByID[id] else { throw TossError.deviceUnavailable }
        let data = try PropertyListEncoder().encode(message)
        guard data.count <= FileSafety.maximumBytes + 100_000 else { throw TossError.tooLarge }
        try session.send(data, toPeers: [peer], with: .reliable)
    }

    private func register(_ peer: MCPeerID, id: String) {
        guard id.count == 64, id.allSatisfy({ $0.isHexDigit }),
              peer.displayName == String(id.prefix(24)) else { return }
        peersByID[id] = peer
        idsByPeer[peer] = id
        if session.connectedPeers.contains(peer) {
            connectedIDs.insert(id)
            onConnected?(id)
        }
    }

    private func connectEligiblePeers() {
        for (id, peer) in peersByID where trustedIDs.contains(id) || pairingAllowed {
            if peerID.displayName < peer.displayName && !session.connectedPeers.contains(peer)
                && !invitedIDs.contains(id) {
                invitedIDs.insert(id)
                browser.invitePeer(peer, to: session, withContext: Data(identityID.utf8), timeout: 12)
            }
        }
    }
}

extension PeerTransport: MCNearbyServiceAdvertiserDelegate {
    nonisolated public func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                                       withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        Task { @MainActor in
            guard let context, let id = String(data: context, encoding: .utf8),
                  id.count == 64, id.allSatisfy({ $0.isHexDigit }),
                  peerID.displayName == String(id.prefix(24)),
                  self.trustedIDs.contains(id) || self.pairingAllowed else {
                invitationHandler(false, nil)
                return
            }
            self.register(peerID, id: id)
            invitationHandler(true, self.session)
        }
    }
}

extension PeerTransport: MCNearbyServiceBrowserDelegate {
    nonisolated public func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID,
                                    withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in
            guard let id = info?["id"], id != self.identityID else { return }
            self.register(peerID, id: id)
            self.connectEligiblePeers()
        }
    }

    nonisolated public func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in
            if let id = self.idsByPeer[peerID] {
                self.invitedIDs.remove(id)
                if !self.session.connectedPeers.contains(peerID) {
                    self.connectedIDs.remove(id)
                    self.onDisconnected?(id)
                }
            }
        }
    }
}

extension PeerTransport: MCSessionDelegate {
    nonisolated public func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            guard let id = self.idsByPeer[peerID] else { return }
            if state == .connected {
                self.invitedIDs.remove(id)
                self.connectedIDs.insert(id)
                self.onConnected?(id)
            } else if state == .notConnected {
                self.invitedIDs.remove(id)
                self.connectedIDs.remove(id)
                self.onDisconnected?(id)
            }
        }
    }

    nonisolated public func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor in
            guard let id = self.idsByPeer[peerID] else { return }
            let limit = self.trustedIDs.contains(id) ? FileSafety.maximumBytes + 100_000 : 8 * 1_024
            guard data.count <= limit,
                  let message = try? PropertyListDecoder().decode(WireMessage.self, from: data) else { return }
            self.onMessage?(message, id)
        }
    }

    nonisolated public func session(_ session: MCSession, didReceive stream: InputStream,
                                    withName streamName: String, fromPeer peerID: MCPeerID) { stream.close() }
    nonisolated public func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String,
                                    fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated public func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String,
                                    fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}
