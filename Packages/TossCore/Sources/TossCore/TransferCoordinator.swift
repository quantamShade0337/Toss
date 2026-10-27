import Foundation

public enum TransferRoute: Equatable, Sendable {
    case nearby, remote, queued, reject
}

/// Chooses a route for one persisted transfer. Receipt timeouts allow remote failover
/// even if an unauthenticated discovery peer keeps a nearby session open.
public enum TransferCoordinator {
    public static func route(for item: TransferItem, trusted: Bool, nearbyConnected: Bool,
                             remoteAvailable: Bool, now: Date = .now) -> TransferRoute {
        guard trusted else { return .reject }
        if let scheduledAt = item.scheduledAt, scheduledAt > now { return .queued }
        let directTimedOut = item.status == .sent &&
            (item.directAttemptedAt ?? item.createdAt) < now.addingTimeInterval(-5)
        if directTimedOut && remoteAvailable { return .remote }
        if nearbyConnected { return .nearby }
        if remoteAvailable { return .remote }
        return .queued
    }
}
