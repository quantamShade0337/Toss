import SwiftUI
import TossCore
import PhotosUI
import UniformTypeIdentifiers
import CoreTransferable
import CoreLocation
import UIKit

struct SendView: View {
    @Environment(TossEngine.self) private var engine
    @AppStorage("last-destination-v1") private var destinationID = ""
    @State private var text = ""
    @FocusState private var draftFocused: Bool
    @State private var fileURL: URL?
    @State private var photo: PhotosPickerItem?
    @State private var importedPhoto: ImportedPhoto?
    @State private var showFilePicker = false
    @State private var showScanner = false
    @State private var schedule: Date = .now
    @State private var scheduleChoice = 0
    @State private var feedback: String?
    @State private var issue: DeliveryIssue?
    @State private var isWorking = false
    @State private var isLoadingPhoto = false
    @State private var lastTransferID: UUID?
    @State private var locationService = CurrentLocationService()

    private var hasContent: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || fileURL != nil || importedPhoto != nil }
    private var destination: TrustedDevice? { engine.devices.first { $0.id == destinationID } }
    private var busy: Bool { isWorking || isLoadingPhoto }
    private var lastTransfer: TransferItem? { engine.transfers.first { $0.id == lastTransferID } }

    var body: some View {
        Form {
            if let lastTransfer {
                Section {
                    NavigationLink(value: TossRoute.transfer(lastTransfer.id)) {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(lastTransfer.deliveryTitle(to: engine.devices.first { $0.id == lastTransfer.receiverDeviceID }?.name ?? "your device"),
                                  systemImage: lastTransfer.status == .failed ? "exclamationmark.circle" : "checkmark.circle")
                                .font(.headline)
                            Text("View transfer and delivery details").font(.subheadline).foregroundStyle(.secondary)
                        }.padding(.vertical, 4)
                    }
                }
            }
            if let issue {
                Section { RecoveryCard(issue: issue) }
            } else if let feedback {
                Section {
                    Label(feedback, systemImage: "checkmark.circle")
                    NavigationLink("View Later", value: TossRoute.later)
                }
            }
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Send something").font(.title2.bold())
                    if let fileURL {
                        attachment(fileURL.lastPathComponent, symbol: "doc")
                    } else if importedPhoto != nil {
                        attachment("Photo selected", symbol: "photo")
                    } else {
                        TextField("Paste text or a link…", text: $text, axis: .vertical)
                            .lineLimit(3...8)
                            .accessibilityIdentifier("send-draft")
                            .focused($draftFocused)
                            .padding(14)
                            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    }
                    if isLoadingPhoto { ProgressView("Preparing photo…") }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 16) { contentActions }.labelStyle(SendActionLabelStyle()).buttonStyle(.borderless)
                        VStack(alignment: .leading, spacing: 16) { contentActions }.buttonStyle(.borderless)
                    }
                }.padding(.vertical, 8)
            } footer: { Text("Send one item at a time. Files and photos up to 20 MB.") }
            .disabled(busy)

            Section("Send to") {
                if engine.devices.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Connect your first device", systemImage: "laptopcomputer.and.iphone").font(.headline)
                        Text("On your Mac, open Toss → Devices → Add Device. Then scan the code here.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Button("Connect a Device", systemImage: "qrcode.viewfinder") { showScanner = true }
                            .buttonStyle(.bordered)
                    }.padding(.vertical, 4)
                } else {
                    Picker("Device", selection: $destinationID) {
                        ForEach(engine.devices) { Text($0.name).tag($0.id) }
                    }
                    if let destination {
                        Label(engine.onlineIDs.contains(destination.id) ? "Available nearby" : "Toss will deliver when available", systemImage: "network")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }.disabled(busy)
            Section {
                Picker("When", selection: $scheduleChoice) {
                    Text("Now").tag(0)
                    Text("Tonight, 8 PM").tag(1)
                    Text("Tomorrow, 8 AM").tag(2)
                    Text("Choose date").tag(3)
                }
                if scheduleChoice == 3 { DatePicker("Date & time", selection: $schedule, in: Date.now...) }
                if scheduleChoice != 0 {
                    Text("Keep Toss open at the scheduled time. Otherwise, it sends the next time you open Toss.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.disabled(busy)
            Section {
                Button {
                    Task { await send() }
                } label: {
                    HStack {
                        Spacer()
                        if isWorking { ProgressView().tint(.white) }
                        else { Label(scheduleChoice == 0 ? "Send" : "Schedule Send", systemImage: "arrow.up.right") }
                        Spacer()
                    }.padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("send-confirm")
                .disabled(!hasContent || destination == nil || busy)
                Button("Save for Later on This Device", systemImage: "bookmark") { Task { await saveLocally() } }
                    .disabled(!hasContent || busy)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Send")
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { draftFocused = false }
            }
        }
        .sheet(isPresented: $showScanner) { PairingScannerView() }
        .onChange(of: engine.devices, initial: true) { _, devices in
            if !devices.contains(where: { $0.id == destinationID }) { destinationID = devices.first?.id ?? "" }
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.item]) { result in
            switch result {
            case .success(let url):
                resetFeedback(); fileURL = url; importedPhoto = nil; photo = nil; text = ""
            case .failure: issue = .storage
            }
        }
        .task(id: photo) {
            guard let photo else { return }
            isLoadingPhoto = true
            defer { isLoadingPhoto = false }
            do {
                guard let loaded = try await photo.loadTransferable(type: ImportedPhoto.self) else { throw TossError.invalidContent }
                try Task.checkCancellation()
                importedPhoto = loaded; fileURL = nil; text = ""; resetFeedback()
            } catch is CancellationError { }
            catch { issue = DeliveryIssue(error: error) }
        }
    }

    @ViewBuilder private var contentActions: some View {
        PhotosPicker(selection: $photo, matching: .images) { Label("Photo", systemImage: "photo") }
        Button("File", systemImage: "doc") { showFilePicker = true }
        Button("Paste", systemImage: "doc.on.clipboard") {
            resetFeedback()
            if let image = UIPasteboard.general.image, let data = image.pngData() {
                if data.count > FileSafety.maximumBytes { issue = .tooLarge; return }
                importedPhoto = ImportedPhoto(data: data, type: .png); fileURL = nil; text = ""
            } else if let value = UIPasteboard.general.string ?? UIPasteboard.general.url?.absoluteString {
                text = value; fileURL = nil; importedPhoto = nil; photo = nil
            } else { issue = .invalidContent }
        }
        .accessibilityLabel("Paste Clipboard")
        Menu {
            Button("Current Location", systemImage: "location") {
                locationService.request { coordinate in
                    if let coordinate {
                        text = "https://maps.apple.com/?ll=\(coordinate.latitude),\(coordinate.longitude)"
                        fileURL = nil; importedPhoto = nil; resetFeedback()
                    } else { showLocationError = true }
                }
            }
        } label: { Label("More", systemImage: "ellipsis.circle") }
        .alert("Location unavailable", isPresented: $showLocationError) {
            Button("Open Settings") { openAppSettings() }
            Button("Cancel", role: .cancel) { }
        } message: { Text("Allow location access for Toss in Settings, or paste an address instead.") }
    }
    @State private var showLocationError = false

    private func attachment(_ title: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            Label(title, systemImage: symbol).lineLimit(2)
            Spacer()
            Button("Remove", systemImage: "xmark.circle.fill") { fileURL = nil; importedPhoto = nil; photo = nil }
                .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("Remove attachment")
        }
        .padding(12).background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private func plannedDate() -> Date? {
        switch scheduleChoice {
        case 1:
            guard let tonight = Calendar.current.date(bySettingHour: 20, minute: 0, second: 0, of: .now) else { return nil }
            return tonight > .now ? tonight : Calendar.current.date(byAdding: .day, value: 1, to: tonight)
        case 2: return Calendar.current.date(byAdding: .day, value: 1, to: Date.now).flatMap {
            Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: $0)
        }
        case 3: return schedule
        default: return nil
        }
    }

    private func send() async {
        guard !busy, hasContent, let destination else { return }
        isWorking = true; resetFeedback()
        defer { isWorking = false }
        do {
            let item: TransferItem
            if let fileURL { item = try await engine.sendFile(fileURL, to: destination.id, scheduledAt: plannedDate()) }
            else if let importedPhoto {
                item = try await engine.sendData(importedPhoto.data, filename: importedPhoto.filename,
                    typeIdentifier: importedPhoto.type.identifier, to: destination.id, scheduledAt: plannedDate())
            } else { item = try await engine.sendText(text, to: destination.id, scheduledAt: plannedDate()) }
            lastTransferID = item.id
            clearDraft()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch { issue = DeliveryIssue(error: error) }
    }

    private func saveLocally() async {
        guard !busy, hasContent else { return }
        isWorking = true; resetFeedback()
        defer { isWorking = false }
        do {
            if let fileURL {
                let data = try await Task.detached(priority: .userInitiated) { try FileSafety.load(fileURL) }.value
                try await engine.saveLocally(data: data, filename: fileURL.lastPathComponent,
                    typeIdentifier: UTType(filenameExtension: fileURL.pathExtension)?.identifier)
            } else if let importedPhoto {
                try await engine.saveLocally(data: importedPhoto.data, filename: importedPhoto.filename, typeIdentifier: importedPhoto.type.identifier)
            } else { try await engine.saveLocally(text: text) }
            feedback = "Saved for Later on this device"
            clearDraft()
        } catch { issue = DeliveryIssue(error: error) }
    }

    private func clearDraft() { draftFocused = false; text = ""; fileURL = nil; importedPhoto = nil; photo = nil; scheduleChoice = 0 }
    private func resetFeedback() { feedback = nil; issue = nil; lastTransferID = nil }
}

private struct ImportedPhoto: Transferable {
    let data: Data
    let type: UTType
    var filename: String { "Photo.\(type.preferredFilenameExtension ?? "jpg")" }
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let data = try FileSafety.load(received.file)
            let type = UTType(filenameExtension: received.file.pathExtension) ?? .jpeg
            try FileSafety.validate(data, typeIdentifier: type.identifier)
            return ImportedPhoto(data: data, type: type)
        }
    }
}

func openAppSettings() {
    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
}

@MainActor
private final class CurrentLocationService: NSObject, @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var completion: ((CLLocationCoordinate2D?) -> Void)?
    override init() { super.init(); manager.delegate = self }
    func request(_ completion: @escaping (CLLocationCoordinate2D?) -> Void) {
        self.completion = completion
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        else if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted { finish(nil) }
        else { manager.requestLocation() }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard completion != nil else { return }
        if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways { manager.requestLocation() }
        else if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted { finish(nil) }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) { finish(locations.last?.coordinate) }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { finish(nil) }
    private func finish(_ coordinate: CLLocationCoordinate2D?) { completion?(coordinate); completion = nil }
}

private struct SendActionLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 6) {
            configuration.icon.font(.title3)
            configuration.title.font(.caption).fixedSize(horizontal: true, vertical: false)
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .contentShape(Rectangle())
    }
}
