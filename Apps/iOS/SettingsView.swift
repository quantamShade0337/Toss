import SwiftUI
import TossCore
import UserNotifications

struct SettingsView: View {
    @Environment(TossEngine.self) private var engine
    @AppStorage("appearance-v1") private var appearance = "system"
    @AppStorage("history-retention-days") private var historyRetentionDays = 0
    @AppStorage("notification-previews-v1") private var notificationPreviews = false
    @State private var showScanner = false
    @State private var showClear = false

    var body: some View {
        Form {
            Section("General") {
                Picker("Appearance", selection: $appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                NotificationSettingsView()
                Toggle("Show content in notifications", isOn: $notificationPreviews)
            }
            Section("Delivery") {
                RemoteDeliveryStatusView()
            }
            Section("Devices") {
                ForEach(engine.devices) { device in
                    NavigationLink {
                        DeviceSettingsView(device: device)
                    } label: { DeviceRow(device: device, online: engine.onlineIDs.contains(device.id)) }
                }
                Button("Add device", systemImage: "plus") { showScanner = true }
            }
            Section("Transfers") {
                LabeledContent("Maximum file size", value: "20 MB")
                Picker("History Retention", selection: $historyRetentionDays) {
                    Text("Forever").tag(0)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                }
                .onChange(of: historyRetentionDays) { _, days in Task { await engine.applyRetention(days: days) } }
            }
            Section("Privacy & Security") {
                NavigationLink("Privacy") { PrivacyView() }
                Button("Clear History", role: .destructive) { showClear = true }
            }
            Section("About") {
                LabeledContent("Version", value: "1.0")
            }
            #if DEBUG
            Section("Diagnostics") {
                LabeledContent("Device ID", value: String(engine.identity.id.prefix(12)))
                LabeledContent("Trusted devices", value: "\(engine.devices.count)")
                LabeledContent("Pending sends", value: "\(engine.transfers.filter { $0.senderDeviceID == engine.identity.id && $0.status == .queued }.count)")
                LabeledContent("Waiting for device", value: "\(engine.transfers.filter { $0.senderDeviceID == engine.identity.id && $0.status == .waitingForDevice }.count)")
                LabeledContent("Nearby devices", value: "\(engine.onlineIDs.count)")
                if let sync = engine.lastRemoteSync { LabeledContent("Last sync", value: sync.formatted()) }
                LabeledContent("Last error", value: engine.errorMessage ?? "None")
            }
            #endif
        }
        .navigationTitle("Settings")
        .sheet(isPresented: $showScanner) { PairingScannerView() }
        .confirmationDialog("Delete all transfer history?", isPresented: $showClear) {
            Button("Delete History", role: .destructive) {
                Task { await engine.clearHistory() }
            }
        }
    }
}

struct DeviceSettingsView: View {
    @Environment(TossEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    @State var device: TrustedDevice
    @State private var showForget = false

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $device.name)
                    .onSubmit { Task { await engine.updateDevice(device) } }
                Toggle("Auto-accept transfers", isOn: $device.autoAccept)
                    .onChange(of: device.autoAccept) { _, _ in Task { await engine.updateDevice(device) } }
                Toggle("Notifications", isOn: $device.notificationsEnabled)
                    .onChange(of: device.notificationsEnabled) { _, enabled in
                        Task {
                            if enabled { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
                            await engine.updateDevice(device)
                        }
                    }
            }
            Section {
                Button("Forget Device", role: .destructive) { showForget = true }
            } footer: {
                Text("Forgetting removes this device's trusted public key. Pair again to send or receive.")
            }
        }
        .navigationTitle("Device")
        .toolbar { Button("Save") { Task { if await engine.updateDevice(device) { dismiss() } } } }
        .confirmationDialog("Forget \(device.name)?", isPresented: $showForget) {
            Button("Forget Device", role: .destructive) { Task { if await engine.forget(device) { dismiss() } } }
        }
    }
}

struct PrivacyView: View {
    var body: some View {
        List {
            Label("Nearby transfers go directly to paired devices. When apart, Toss stores encrypted transfers in your private iCloud account until delivered.", systemImage: "network")
            Label("Stored history and files are encrypted. Previews are decrypted temporarily on this device.", systemImage: "lock.shield")
            Label("Toss reads your clipboard only when you tap Clipboard or paste.", systemImage: "doc.on.clipboard")
            Label("No analytics, tracking, or external AI services.", systemImage: "hand.raised")
            Text("When apart, the receiving device fetches pending transfers when Toss opens or is woken by the system. Background notifications are not guaranteed.")
                .foregroundStyle(.secondary)
        }
        .navigationTitle("Privacy")
    }
}
