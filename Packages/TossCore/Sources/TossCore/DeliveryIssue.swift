import CloudKit
import Foundation

/// Safe, stable explanations for persisted failures. Never show raw system errors or paths.
public enum DeliveryIssue: String, Codable, Sendable, Hashable {
    case offline, signIn, cloudStorage, serviceUnavailable, configuration
    case invalidContent, tooLarge, untrustedDevice, verification, storage, missingFile, declined, expired, unknown

    public init(error: Error) {
        if let error = error as? TossError {
            switch error {
            case .tooLarge: self = .tooLarge
            case .invalidContent: self = .invalidContent
            case .untrustedDevice: self = .untrustedDevice
            case .authenticationFailed, .corruptData: self = .verification
            case .storageUnavailable: self = .storage
            case .deviceUnavailable: self = .offline
            case .invalidPairingCode, .pairingExpired: self = .verification
            }
        } else if let error = error as? CKError {
            switch error.code {
            case .notAuthenticated: self = .signIn
            case .quotaExceeded: self = .cloudStorage
            case .networkFailure, .networkUnavailable: self = .offline
            case .badContainer, .missingEntitlement, .permissionFailure: self = .configuration
            case .serviceUnavailable, .requestRateLimited, .zoneBusy: self = .serviceUnavailable
            default: self = .unknown
            }
        } else if (error as NSError).domain == NSCocoaErrorDomain {
            self = [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains((error as NSError).code) ? .missingFile : .storage
        } else { self = .unknown }
    }

    public var title: String {
        switch self {
        case .offline: "Waiting for a connection"
        case .signIn: "Sign in to iCloud"
        case .cloudStorage: "iCloud storage is full"
        case .serviceUnavailable: "Delivery is temporarily unavailable"
        case .configuration: "Delivery needs attention"
        case .invalidContent: "This item isn't supported"
        case .tooLarge: "This file is too large"
        case .untrustedDevice: "Connect this device again"
        case .verification: "Couldn't verify this transfer"
        case .storage: "Couldn't access saved data"
        case .missingFile: "File unavailable"
        case .declined: "Transfer declined"
        case .expired: "Delivery expired"
        case .unknown: "Couldn't complete this action"
        }
    }

    public var guidance: String {
        switch self {
        case .offline: "Connect to Wi-Fi or cellular, or open Toss on both devices nearby. Queued items retry automatically while Toss is open."
        case .signIn: "In system Settings, sign in to the same iCloud account on both devices. Then return to Toss and check again. Nearby sending is still available."
        case .cloudStorage: "Free up space in iCloud storage in system Settings, then try again. You can also open Toss on both devices nearby."
        case .serviceUnavailable: "Your item is saved on this device. Leave Toss open; it will retry automatically. You can also check again below."
        case .configuration: "Delivery between networks isn't available for this installation. Update Toss and check again. Nearby sending is still available."
        case .invalidContent: "Choose another file, or paste plain text or an http/https link. Your draft has been kept so you can change it."
        case .tooLarge: "Choose a file up to 20 MB, or reduce its size and select it again."
        case .untrustedDevice: "Open Devices in Toss on your Mac, choose Add Device, then scan the new code on your iPhone or iPad."
        case .verification: "Toss couldn't verify the data, so it wasn't opened. Ask the sending device to send a fresh copy. If this continues, forget the device and pair again."
        case .missingFile: "Choose the original file again, or ask the sending device for a fresh copy. Toss can’t restore a file that is no longer on this device."
        case .storage: "Unlock your device and check that it has free storage, then try again. If this continues, close and reopen Toss. Don't delete the app if you need its saved items."
        case .declined: "The receiving device declined this item. Check with that device before sending a fresh copy."
        case .expired: "The receiving device didn't confirm delivery within 30 days. Open Toss on that device, then send a fresh copy."
        case .unknown: "Your draft or saved item is still available. Try again. If this continues, close and reopen Toss."
        }
    }

    public var retriesAutomatically: Bool {
        [.offline, .signIn, .serviceUnavailable, .unknown].contains(self)
    }
}

public extension TransferItem {
    func deliveryTitle(to deviceName: String, now: Date = .now) -> String {
        if status == .queued, let scheduledAt, scheduledAt > now { return "Scheduled for \(deviceName)" }
        switch status {
        case .queued: return "Queued for \(deviceName)"
        case .discovering, .sending, .sent: return "Sending to \(deviceName)…"
        case .waitingForDevice: return "Waiting for \(deviceName)"
        case .delivered: return "Delivered to \(deviceName)"
        case .failed: return failure?.title ?? "Couldn't send to \(deviceName)"
        case .cancelled: return "Cancelled"
        }
    }
}
