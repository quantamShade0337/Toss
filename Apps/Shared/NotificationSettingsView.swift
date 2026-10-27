import SwiftUI
import UserNotifications
#if os(iOS)
import UIKit
#else
import AppKit
#endif

struct NotificationSettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var status: UNAuthorizationStatus = .notDetermined
    @State private var failed = false
    private var isEnabled: Bool {
        #if os(iOS)
        status == .authorized || status == .provisional || status == .ephemeral
        #else
        status == .authorized || status == .provisional
        #endif
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isEnabled {
                Label("Notifications enabled", systemImage: "bell.badge")
            } else {
                Button(status == .denied ? "Open Notification Settings" : "Enable Notifications", systemImage: "bell") {
                    Task {
                        if status == .denied {
                            #if os(iOS)
                            if let url = URL(string: UIApplication.openNotificationSettingsURLString) { await UIApplication.shared.open(url) }
                            #else
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
                            #endif
                        } else {
                            do { _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]); failed = false }
                            catch { failed = true }
                        }
                        await refresh()
                    }
                }
                if status == .denied {
                    Text("Notifications are off. Turn them on in system Settings to hear when a transfer arrives.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if failed { Text("Couldn't enable notifications. Try again in system Settings.").font(.caption).foregroundStyle(.secondary) }
        }
        .task { await refresh() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await refresh() } } }
    }
    private func refresh() async { status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus }
}
