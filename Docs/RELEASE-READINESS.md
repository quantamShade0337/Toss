# Toss release verification

This is an engineering release candidate. Shipping requires a signed, provisioned build and the device checks below. Automated checks cannot establish zero defects or zero vulnerabilities.

## Product and reliability changes — 21 October 2026

- Send preserves drafts on failure, prevents concurrent submissions, remembers the destination, and exposes the 20 MB limit before selection. Successful queueing links to a live transfer detail screen. Saving for Later explicitly identifies this device.
- File/photo/text selection is exclusive, attachments can be removed, and photo imports use a bounded file read. Saving a file locally no longer reads it on the main actor.
- Transfer details observe current state. Failures persist with specific guidance for iCloud storage, connectivity, trust, integrity, expiration, and local storage. Declined and expired transfers can be sent as a fresh copy.
- Pairing stays visible through confirmation, connection, timeout, and success. Camera denial has Settings and link alternatives. Mac QR codes show expiry; closing pairing cancels its offer.
- Navigation uses stable transfer IDs so live status updates cannot reopen History above a detail screen. The Send keyboard has an explicit Done action; attachment controls adapt to available space and Dynamic Type. The accent follows the system appearance.
- Empty Inbox and Send screens lead directly to pairing. Filtered and empty History states have distinct copy. Inbox/Mac refresh fetch remote changes.
- Missing files show recovery instead of silent actions or endless previews. A failed save/accept/delete does not dismiss the detail screen. Notification denial explains how to enable access.
- Share extensions confirm what was queued and explain that opening Toss sends it. They do not falsely claim delivery or discard an error after a timer.
- Interrupted outgoing sends are recovered on startup. Accepted incoming items and their receipts are written together. Acknowledgements remain possible after visible History deletion. A receipt arriving before upload completion remains delivered.
- Retried CloudKit uploads verify the already-stored outgoing ciphertext with the correct route and compare all content, including file bytes. Incoming recipient checks remain strict. Bad ciphertext/serialized records cannot indefinitely block subsequent valid mailbox records.
- Trust is checked again inside the storage transaction when committing an incoming transfer or receipt. Pending expired content becomes an actionable failure rather than waiting forever.

## Automated evidence

`Packages/TossCore/Tests/TossCoreTests/TossCoreTests.swift` contains 22 test functions (including a four-case failure-mapping test). The latest core run passed. Tests cover crypto tampering and routing, pairing, content and file validation, encryption at rest, replay prevention, account changes, revocation, route fallback, restart recovery, receipt races, idempotent remote retries, and malformed-record recovery. A deterministic mailbox stub exercises the engine without a live Apple account.

`Tests/TossUITests/TossUITests.swift` exercises onboarding/navigation, local saving, a failed transfer's recovery and live status change, a missing-file preview, an invalid pairing link, the largest accessibility text size, and landscape navigation. Debug-only fixtures use a separate temporary directory and an offline mailbox; they never reset personal App Group data or Keychain keys. Fixtures are excluded from Release builds.

On 21 October 2026, all 22 core tests passed. Six UI scenarios passed on iPhone 16 and iPad Air 13-inch (M3), both on iOS 18.5; the iPad runs used dark appearance. The iPhone accessibility and missing-file checks were run separately after the initial five-flow suite. The final iPad recovery checks and a seventh, landscape-navigation check also passed. The iOS 27 XCTest runner stalled in the dynamic linker before tests started, so those runs are not counted as app verification.

macOS Debug and Release builds passed with the embedded share extension. The iOS simulator Debug build and unsigned iOS device Release build passed with the embedded share extension. The final plist change declares all iPad orientations for multitasking. Protected entitlements, live CloudKit, APNs, and extension handoff were not tested by these builds.

UI tests attach screenshots to the Xcode result bundles. Final examples: [delivery recovery](Screenshots/ipad-delivery-recovery.png) and [missing-file recovery](Screenshots/ipad-file-recovery.png).

## Required device acceptance checks

| Scenario | Required result | Status |
| --- | --- | --- |
| Signed iPhone + Mac QR pairing | Both screens confirm the same device/code; cancel, expired code, no network permission, timeout, and retry all behave clearly | Needs provisioned devices |
| Mac on Wi-Fi, iPhone on cellular | Text, image, PDF, and near-20 MB file arrive exactly once; sender is Delivered only after receipt | Needs live CloudKit |
| Recipient offline, then reopened | Waiting state persists through sender restart; recipient receives once; sender updates after sync | Needs live CloudKit |
| Share from Safari/Photos/Files/Finder | Shared identity and encrypted App Group are accessible; app sends the queued item when opened | Needs signed extensions |
| Disk full or locked Keychain | Draft/item survives; failure gives recovery; no plaintext fallback or silent storage reset | Needs physical fault testing |
| Background pushes delayed/dropped | Foreground sync catches up; no reliance on one push per item | Needs APNs/provisioning |
| VoiceOver, largest Dynamic Type, keyboard, Reduce Motion | All actions reachable and meaningfully named; no clipped recovery instructions; focus predictable | Human accessibility pass needed |
| Production CloudKit schema | Release-signed apps can create/fetch/delete both encrypted record types and subscription | Account owner deployment needed |
| Independent security review | Review protocol, key lifecycle, revocation, temporary files, and signed entitlements | Not performed |

## Remaining constraints

- The same iCloud account is required for remote delivery. Initial QR pairing requires nearby devices.
- iOS background execution and push delivery are best effort. Scheduled sending requires Toss to be running; otherwise it sends when reopened. The UI states this.
- Cloud payload expiry is client-enforced. A ciphertext may remain past 30 days if no relevant device runs again.
- Long-term ECDH keys do not provide forward secrecy. The underlying nearby discovery identity is not authenticated until the application envelope/receipt is verified; remote fallback limits waiting when available.
- Company-level release operations still need a public support contact, privacy-policy URL, production signing, App Store metadata, device QA, and a supported key-recovery/rotation policy. These cannot be validated by an unsigned local build.
