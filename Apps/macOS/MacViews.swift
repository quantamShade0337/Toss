import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI
import TossCore
import UniformTypeIdentifiers
import UserNotifications
import Observation

enum MacSection: String, CaseIterable, Identifiable {
    case inbox = "Inbox", sent = "Sent", history = "History", later = "Later", devices = "Devices", settings = "Settings"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .inbox: "tray"
        case .sent: "paperplane"
        case .history: "clock.arrow.circlepath"
        case .later: "bookmark"
        case .devices: "laptopcomputer.and.iphone"
        case .settings: "gearshape"
        }
    }
}

@Observable final class MacRoute {
    var section: MacSection? = .inbox
    var selectedItem: TransferItem?
}

struct MacMainView: View {
    @Environment(TossEngine.self) private var engine
    @Environment(MacRoute.self) private var route
    @Environment(\.openWindow) private var openWindow
    @State private var query = ""

    private var items: [TransferItem] {
        engine.transfers.filter { item in
            let included: Bool = switch route.section {
            case .inbox: item.receiverDeviceID == engine.identity.id && !item.isArchived
            case .sent: item.senderDeviceID == engine.identity.id
            case .later: item.isArchived || (item.scheduledAt != nil && item.status == .queued)
            default: true
            }
            return included && (query.isEmpty || [item.title, item.subtitle, item.text ?? "", item.filename ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(query) })
        }
    }

    var body: some View {
        @Bindable var route = route
        NavigationSplitView {
            List(MacSection.allCases, selection: $route.section) { entry in
                Label(entry.rawValue, systemImage: entry.symbol).tag(entry)
            }
            .navigationTitle("Toss")
            .safeAreaInset(edge: .bottom) {
                Button { openWindow(id: "compose") } label: {
                    Label("Send Something", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).padding(12)
            }
        } content: {
            if route.section == .devices { MacDevicesView() }
            else if route.section == .settings { MacSettingsView() }
            else {
                List(selection: $route.selectedItem) {
                    ForEach(items) { item in
                        TransferRow(item: item,
                                    deviceName: engine.devices.first { $0.id == (item.senderDeviceID == engine.identity.id ? item.receiverDeviceID : item.senderDeviceID) }?.name ?? "This device",
                                    needsApproval: item.receiverDeviceID == engine.identity.id && item.status == .queued,
                                    outgoing: item.senderDeviceID == engine.identity.id && item.receiverDeviceID != engine.identity.id)
                            .tag(item)
                            .contextMenu {
                                Button("Save for Later") { Task { await engine.archive(item) } }
                                if item.senderDeviceID == engine.identity.id, item.status == .failed {
                                    Button("Retry") { Task { await engine.retry(item) } }
                                }
                                Button("Delete", role: .destructive) { Task { await engine.delete(item) } }
                            }
                    }
                }
                .overlay {
                    if items.isEmpty {
                        ContentUnavailableView("Nothing here yet", systemImage: route.section == .later ? "bookmark" : "tray",
                                               description: Text("Transfers between your devices appear here."))
                    }
                }
                .searchable(text: $query, prompt: "Search transfers")
                .navigationTitle(route.section?.rawValue ?? "Toss")
                .toolbar { Button("Refresh", systemImage: "arrow.clockwise") { Task { await engine.syncRemote(); await engine.refresh() } } }
            }
        } detail: {
            if let selectedItem = route.selectedItem,
               let current = engine.transfers.first(where: { $0.id == selectedItem.id }) {
                TransferDetailView(item: current).id(current.id)
            }
            else { ContentUnavailableView("Select a transfer", systemImage: "tray") }
        }
        .navigationSplitViewStyle(.balanced)
        .task { engine.start() }
        .alert("Toss", isPresented: Binding(get: { engine.errorMessage != nil },
                                             set: { if !$0 { engine.errorMessage = nil } })) {
            Button("OK") { engine.errorMessage = nil }
        } message: { Text(engine.errorMessage ?? "") }
    }
}

struct MacMenuView: View {
    @Environment(TossEngine.self) private var engine
    @Environment(MacRoute.self) private var route
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Toss").font(.title3.bold())
                Spacer()
                Image(systemName: "paperplane.fill").foregroundStyle(.tint)
            }
            ForEach(Array(engine.transfers.prefix(4))) { item in
                Button {
                    route.section = .history
                    route.selectedItem = item
                    openWindow(id: "main")
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.kind.symbol).foregroundStyle(.tint).frame(width: 22)
                        Text(item.title).lineLimit(1)
                        Spacer()
                        Text(item.senderDeviceID == engine.identity.id ? "→" : "←").foregroundStyle(.secondary)
                    }.font(.subheadline)
                }.buttonStyle(.plain)
            }
            if engine.transfers.isEmpty { Text("Your recent transfers appear here.").foregroundStyle(.secondary) }
            Divider()
            Button("Send Something", systemImage: "plus") { openWindow(id: "compose") }
            Button("Open Inbox", systemImage: "tray") { route.section = .inbox; openWindow(id: "main") }
            if !engine.devices.isEmpty {
                Divider()
                Text("DEVICES").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(engine.devices) { DeviceRow(device: $0, online: engine.onlineIDs.contains($0.id)) }
            }
            Divider()
            Button("Settings", systemImage: "gearshape") { route.section = .settings; openWindow(id: "main") }
        }
        .padding(18)
        .frame(width: 320)
        .task { engine.start(); await engine.refresh() }
    }
}

struct MacComposerView: View {
    @Environment(TossEngine.self) private var engine
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var text = ""
    @State private var fileURL: URL?
    @State private var imageData: Data?
    @State private var destinationID: String?
    @State private var message: String?
    @State private var issue: DeliveryIssue?
    @State private var isWorking = false
    @AppStorage("last-destination-v1") private var lastDestinationID = ""
    @Environment(MacRoute.self) private var route
    @Environment(\.openWindow) private var openWindow
    @FocusState private var focused: Bool

    private var destination: TrustedDevice? {
        engine.devices.first { $0.id == destinationID }
    }
    private var isLocalAction: Bool { destinationID == "__clipboard__" || destinationID == "__later__" }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "paperplane.fill").foregroundStyle(.tint)
                Text("Send anything…").font(.headline)
                Spacer()
                Text("⌘⇧Space").font(.caption).foregroundStyle(.secondary)
            }
            TextField("Paste a link, type text, or drop a file", text: $text, axis: .vertical)
                .font(.title3).lineLimit(2...5)
                .textFieldStyle(.plain)
                .focused($focused)
                .disabled(fileURL != nil || imageData != nil)
                .onSubmit { Task { await send() } }
                .padding(14)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            if let fileURL {
                HStack {
                    Label(fileURL.lastPathComponent, systemImage: "doc").font(.subheadline).lineLimit(1)
                    Spacer()
                    Button("Remove", systemImage: "xmark.circle") { self.fileURL = nil }
                }
            }
            if imageData != nil {
                HStack {
                    Label("Image ready", systemImage: "photo")
                    Spacer()
                    Button("Remove", systemImage: "xmark.circle") { imageData = nil }
                }
            }
            Text("Files up to 20 MB").font(.caption).foregroundStyle(.secondary)
            if let issue { RecoveryCard(issue: issue) }
            if engine.devices.isEmpty {
                Button("Connect a Device", systemImage: "laptopcomputer.and.iphone") {
                    route.section = .devices; openWindow(id: "main"); dismissWindow(id: "compose")
                }.buttonStyle(.borderless)
            }
            HStack {
                Button("Paste Clipboard", systemImage: "doc.on.clipboard") {
                    if let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self]) as? [URL],
                       let first = urls.first, first.isFileURL { fileURL = first; imageData = nil; text = "" }
                    else if let tiff = NSPasteboard.general.data(forType: .tiff) {
                        imageData = tiff; fileURL = nil; text = ""
                    } else { text = NSPasteboard.general.string(forType: .string) ?? ""; fileURL = nil; imageData = nil }
                }
                .buttonStyle(.borderless)
                Spacer()
                Picker("Send to", selection: $destinationID) {
                    Text("Choose device").tag(String?.none)
                    ForEach(engine.devices) { device in
                        Text("\(device.name) · \(engine.onlineIDs.contains(device.id) ? "Available nearby" : "Will deliver when available")")
                            .tag(Optional(device.id))
                    }
                    Divider()
                    Text("Clipboard").tag(Optional("__clipboard__"))
                    Text("Save for Later").tag(Optional("__later__"))
                }
                .labelsHidden().frame(width: 210)
            }
            HStack {
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button(destinationID == "__clipboard__" ? "Copy" : destinationID == "__later__" ? "Save" : "Send",
                       systemImage: destinationID == "__clipboard__" ? "doc.on.doc" : destinationID == "__later__" ? "bookmark" : "arrow.up") {
                    Task { await send() }
                }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled((destination == nil && !isLocalAction) || (text.isEmpty && fileURL == nil && imageData == nil))
            }
        }
        .padding(22)
        .frame(width: 560)
        .disabled(isWorking)
        .overlay(alignment: .topTrailing) { if isWorking { ProgressView().controlSize(.small).padding(22) } }
        .onDrop(of: [UTType.fileURL.identifier, UTType.image.identifier, UTType.plainText.identifier], isTargeted: nil) { providers in
            guard !isWorking, let provider = providers.first else { return false }
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                        DispatchQueue.main.async { fileURL = url; imageData = nil }
                    } else if let url = item as? URL { DispatchQueue.main.async { fileURL = url; imageData = nil } }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { item, _ in
                    let image = item as? NSImage ?? (item as? Data).flatMap(NSImage.init(data:))
                    if let data = image?.tiffRepresentation { DispatchQueue.main.async { imageData = data; fileURL = nil } }
                }
            } else {
                provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                    if let string = item as? String { DispatchQueue.main.async { text = string; fileURL = nil; imageData = nil } }
                }
            }
            return true
        }
        .onAppear {
            focused = true
            destinationID = engine.devices.contains { $0.id == lastDestinationID } ? lastDestinationID : engine.devices.first?.id ?? "__later__"
        }
    }

    private func send() async {
        guard !isWorking, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || fileURL != nil || imageData != nil else { return }
        isWorking = true; issue = nil
        defer { isWorking = false }
        do {
            if destinationID == "__clipboard__" {
                NSPasteboard.general.clearContents()
                if let fileURL { NSPasteboard.general.writeObjects([fileURL as NSURL]) }
                else if let imageData, let image = NSImage(data: imageData) { NSPasteboard.general.writeObjects([image]) }
                else { NSPasteboard.general.setString(text, forType: .string) }
                message = "Copied to Clipboard"
                try? await Task.sleep(for: .milliseconds(350))
                dismissWindow(id: "compose")
                text = ""; fileURL = nil; imageData = nil
                return
            }
            if destinationID == "__later__" {
                if let fileURL {
                    let data = try await Task.detached(priority: .userInitiated) { try FileSafety.load(fileURL) }.value
                    let type = UTType(filenameExtension: fileURL.pathExtension)
                    try await engine.saveLocally(data: data, filename: fileURL.lastPathComponent,
                                                 typeIdentifier: type?.identifier)
                } else if let imageData {
                    try await engine.saveLocally(data: imageData, filename: "Clipboard Image.tiff", typeIdentifier: UTType.tiff.identifier)
                } else { try await engine.saveLocally(text: text) }
                message = "Saved for later"
                try? await Task.sleep(for: .milliseconds(350))
                dismissWindow(id: "compose")
                text = ""; fileURL = nil; imageData = nil
                return
            }
            guard let destination else { return }
            lastDestinationID = destination.id
            let item: TransferItem
            if let fileURL { item = try await engine.sendFile(fileURL, to: destination.id) }
            else if let imageData {
                item = try await engine.sendData(imageData, filename: "Clipboard Image.tiff",
                                                 typeIdentifier: UTType.tiff.identifier, to: destination.id)
            }
            else { item = try await engine.sendText(text, to: destination.id) }
            let status = (try await engine.repository.snapshot()).transfers.first { $0.id == item.id }?.status
            if status == .failed {
                message = "Couldn't send to \(destination.name). Try again from History."
                return
            }
            message = status == .delivered ? "Delivered to \(destination.name)" :
                status == .waitingForDevice ? "Waiting for \(destination.name)" :
                status == .sent ? "Sending to \(destination.name)…" : "Queued for \(destination.name)"
            try? await Task.sleep(for: .milliseconds(500))
            dismissWindow(id: "compose")
            text = ""; fileURL = nil; imageData = nil
        } catch { issue = DeliveryIssue(error: error) }
    }
}

struct MacDevicesView: View {
    @Environment(TossEngine.self) private var engine
    @State private var showPairing = false
    @State private var selectedDevice: TrustedDevice?

    var body: some View {
        List {
            ForEach(engine.devices) { device in
                Button { selectedDevice = device } label: {
                    DeviceRow(device: device, online: engine.onlineIDs.contains(device.id))
                }.buttonStyle(.plain)
                    .contextMenu {
                        Button("Device Settings…") { selectedDevice = device }
                    }
            }
            if engine.devices.isEmpty { Text("No paired devices yet.").foregroundStyle(.secondary) }
        }
        .navigationTitle("Devices")
        .toolbar { Button("Add Device", systemImage: "plus") { showPairing = true } }
        .sheet(isPresented: $showPairing) { MacPairingView() }
        .sheet(item: $selectedDevice) { MacDeviceSettingsView(device: $0) }
    }
}

private struct MacDeviceSettingsView: View {
    @Environment(TossEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    @State var device: TrustedDevice
    @State private var showForget = false

    var body: some View {
        Form {
            TextField("Name", text: $device.name)
            Toggle("Auto-accept transfers", isOn: $device.autoAccept)
            Toggle("Notifications", isOn: $device.notificationsEnabled)
                .onChange(of: device.notificationsEnabled) { _, enabled in
                    if enabled {
                        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
                    }
                }
            HStack {
                Button("Forget Device", role: .destructive) { showForget = true }
                Spacer()
                Button("Save") { Task { if await engine.updateDevice(device) { dismiss() } } }
                    .buttonStyle(.borderedProminent)
            }
        }
        .formStyle(.grouped)
        .padding(16)
        .frame(width: 420)
        .confirmationDialog("Forget \(device.name)?", isPresented: $showForget) {
            Button("Forget Device", role: .destructive) { Task { if await engine.forget(device) { dismiss() } } }
        }
    }
}

struct MacPairingView: View {
    @Environment(TossEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Text("Connect a device").font(.title2.bold())
            if case .connected(let name) = engine.pairingProgress {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 64)).foregroundStyle(.tint)
                Text("Connected to \(name)").font(.headline)
                Text("Press ⌘⇧Space to send your first item.").foregroundStyle(.secondary)
            } else if let offer = engine.pairingOffer, let url = offer.url {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    if context.date < offer.expiresAt {
                        VStack(spacing: 16) {
                            QRImage(url: url).frame(width: 220, height: 220)
                            Text("On your iPhone or iPad, open Toss → Settings → Add device. Keep both devices nearby for pairing.")
                                .foregroundStyle(.secondary).multilineTextAlignment(.center)
                            Text(offer.verificationCode).font(.system(.title3, design: .monospaced).weight(.semibold))
                            Text("Confirm this code matches on your other device.").font(.caption).foregroundStyle(.secondary)
                            Text("Code expires in \(max(0, Int(offer.expiresAt.timeIntervalSince(context.date)))) seconds")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        ContentUnavailableView("Code expired", systemImage: "clock",
                            description: Text("Choose New Code below, then scan it on your other device."))
                    }
                }
            } else {
                ContentUnavailableView("Couldn't create a code", systemImage: "qrcode", description: Text("Choose New Code to try again."))
            }
            HStack {
                Button("Copy Pairing Link") {
                    if let url = engine.pairingOffer?.url {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    }
                }
                Button("New Code") { generateCode() }
                Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(30).frame(width: 350)
        .onAppear { generateCode() }
        .onDisappear { engine.cancelPairing() }
    }

    private func generateCode() {
        do { try engine.createPairingOffer() }
        catch { engine.errorMessage = error.localizedDescription }
    }
}

private struct QRImage: View {
    let url: URL
    var body: some View {
        Group {
            if let image = makeImage() {
                Image(nsImage: image).interpolation(.none).resizable().scaledToFit()
            } else { ContentUnavailableView("Code unavailable", systemImage: "qrcode") }
        }
    }

    private func makeImage() -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

struct MacSettingsView: View {
    @Environment(TossEngine.self) private var engine
    @Environment(HotKeyCenter.self) private var hotKey
    @AppStorage("appearance-v1") private var appearance = "system"
    @AppStorage("shortcut-v1") private var shortcut = "automatic"
    @AppStorage("history-retention-days") private var historyRetentionDays = 0
    @AppStorage("notification-previews-v1") private var notificationPreviews = false
    @State private var showClear = false

    var body: some View {
        Form {
            Picker("Appearance", selection: $appearance) {
                Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark")
            }
            Picker("Send Shortcut", selection: $shortcut) {
                Text("Automatic").tag("automatic")
                Text("⌘⇧Space").tag("shift")
                Text("⌘⌥Space").tag("option")
            }
            .onChange(of: shortcut) { _, value in hotKey.register(preference: value) }
            if let error = hotKey.registrationError { Text(error).foregroundStyle(.orange) }
            else if hotKey.usesFallback { Text("Using ⌘⌥Space because ⌘⇧Space is unavailable.").foregroundStyle(.secondary) }
            Picker("History Retention", selection: $historyRetentionDays) {
                Text("Forever").tag(0)
                Text("30 days").tag(30)
                Text("90 days").tag(90)
            }
            .onChange(of: historyRetentionDays) { _, days in Task { await engine.applyRetention(days: days) } }
            NotificationSettingsView()
            RemoteDeliveryStatusView()
            Toggle("Show content in notifications", isOn: $notificationPreviews)
            #if DEBUG
            LabeledContent("Device ID", value: String(engine.identity.id.prefix(12)))
            LabeledContent("Trusted devices", value: "\(engine.devices.count)")
            LabeledContent("Nearby devices", value: "\(engine.onlineIDs.count)")
            LabeledContent("Pending sends", value: "\(engine.transfers.filter { $0.senderDeviceID == engine.identity.id && $0.status == .queued }.count)")
            LabeledContent("Waiting for device", value: "\(engine.transfers.filter { $0.senderDeviceID == engine.identity.id && $0.status == .waitingForDevice }.count)")
            if let sync = engine.lastRemoteSync { LabeledContent("Last sync", value: sync.formatted()) }
            LabeledContent("Last error", value: engine.errorMessage ?? "None")
            #endif
            Button("Clear History", role: .destructive) { showClear = true }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .confirmationDialog("Delete all transfer history?", isPresented: $showClear) {
            Button("Delete History", role: .destructive) {
                Task { await engine.clearHistory() }
            }
        }
    }
}
