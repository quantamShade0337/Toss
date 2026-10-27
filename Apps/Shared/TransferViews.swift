import SwiftUI
import TossCore
import UniformTypeIdentifiers
import QuickLook
import Vision
import ImageIO
#if os(iOS)
import UIKit
import Photos
#else
import AppKit
#endif

struct TransferRow: View {
    let item: TransferItem
    let deviceName: String
    var needsApproval = false
    var outgoing = false

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: item.kind.symbol)
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 46, height: 46)
                .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.body.weight(item.isRead ? .regular : .semibold)).lineLimit(1)
                Text(outgoing ? item.deliveryTitle(to: deviceName) : needsApproval ? "Needs approval · \(deviceName)" :
                     item.status == .waitingForDevice ? "Waiting for \(deviceName)" :
                     item.subtitle.isEmpty ? deviceName : "\(item.subtitle) · \(deviceName)")
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 5) {
                Text(item.createdAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                if item.status == .queued || item.status == .waitingForDevice || item.status == .failed {
                    Image(systemName: item.status == .failed ? "exclamationmark.circle" : "clock")
                        .font(.caption).foregroundStyle(item.status == .failed ? .orange : .secondary)
                }
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct TransferDetailView: View {
    @Environment(TossEngine.self) private var engine
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    private let initialItem: TransferItem
    init(item: TransferItem) { initialItem = item }
    private var item: TransferItem { engine.transfers.first { $0.id == initialItem.id } ?? initialItem }
    private var isOutgoing: Bool { item.senderDeviceID == engine.identity.id && item.receiverDeviceID != engine.identity.id }
    private var destinationName: String { engine.devices.first { $0.id == item.receiverDeviceID }?.name ?? "your device" }
    @State private var isRetrying = false
    @State private var previewIssue: DeliveryIssue?
    @State private var isPreparingPreview = false
    @State private var previewURL: URL?
    @State private var exportedURL: URL?
    @State private var showDelete = false
    @State private var showDecline = false
    @State private var feedback: String?
    @State private var showEventSheet = false
    @State private var showOCR = false
    @State private var recognizedText = ""

    private var sourceName: String {
        engine.devices.first(where: { $0.id == item.senderDeviceID })?.name ?? "Your device"
    }
    private var needsApproval: Bool { item.receiverDeviceID == engine.identity.id && item.status == .queued }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 16) {
                    Image(systemName: item.kind.symbol)
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(.tint)
                        .frame(width: 64, height: 64)
                        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title).font(.title2.bold()).textSelection(.enabled)
                        Text(item.subtitle).font(.subheadline).foregroundStyle(.secondary)
                    }
                }

                if isOutgoing {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(item.deliveryTitle(to: destinationName), systemImage: item.status == .delivered ? "checkmark.circle.fill" : item.status == .failed ? "exclamationmark.circle" : "clock")
                            .font(.headline)
                        if let issue = item.failure {
                            Text(issue.guidance).font(.subheadline).foregroundStyle(.secondary)
                        } else if let scheduledAt = item.scheduledAt, item.status == .queued, scheduledAt > .now {
                            Text("\(scheduledAt.formatted(date: .abbreviated, time: .shortened)). Keep Toss open at that time to send; otherwise it sends next time you open the app.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        } else if item.status == .queued {
                            Text("Saved on this device. Toss will retry while open. Connect to the internet, or open Toss on both devices nearby.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        } else if item.status == .waitingForDevice || item.status == .sent {
                            Text("Waiting for confirmation. Open Toss on \(destinationName) to receive it. You can leave this screen.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        if [.failed, .queued].contains(item.status), (item.scheduledAt ?? .distantPast) <= .now,
                           engine.devices.contains(where: { $0.id == item.receiverDeviceID }) {
                            Button(item.failure == .declined || item.failure == .expired ? "Send a Fresh Copy" : "Try Again", systemImage: "arrow.clockwise") {
                                isRetrying = true
                                Task { await engine.retry(item); isRetrying = false }
                            }
                            .buttonStyle(.bordered).disabled(isRetrying)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }
                if let previewIssue {
                    RecoveryCard(issue: previewIssue, title: "Couldn't open this file") {
                        Task { await preparePreview() }
                    }
                }

                if item.kind == .image, let blobID = item.blobID {
                    ImagePreview(blobID: blobID, repository: engine.repository)
                } else if let text = item.text {
                    Text(text)
                        .font(item.kind == .code ? .system(.body, design: .monospaced) : .body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
                }

                VStack(spacing: 10) {
                    if needsApproval {
                        Label("Review this transfer from a trusted device", systemImage: "hand.raised")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    if needsApproval || previewIssue == nil || item.blobID == nil {
                    Button(needsApproval ? "Accept Transfer" : isPreparingPreview ? "Preparing File…" : actionTitle) {
                        if needsApproval { Task { if await engine.approve(item) { dismiss() } } }
                        else { Task { await primaryAction() } }
                    }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(isPreparingPreview && !needsApproval)
                        .frame(maxWidth: .infinity)
                    }
                    if needsApproval {
                        Button("Decline", role: .destructive) { showDecline = true }
                    } else {
                        HStack {
                            Button("Copy", systemImage: "doc.on.doc") { Task { await copyContent() } }
                                .disabled(item.text == nil && exportedURL == nil)
                            Spacer()
                            if let shareURL = exportedURL ?? item.sourceURL {
                                ShareLink(item: shareURL) { Label("Share", systemImage: "square.and.arrow.up") }
                            } else if let text = item.text {
                                ShareLink(item: text) { Label("Share", systemImage: "square.and.arrow.up") }
                            }
                            Spacer()
                            if item.kind == .image {
                                Menu {
                                    #if os(iOS)
                                    Button("Save to Photos", systemImage: "square.and.arrow.down") { Task { await saveImageToPhotos() } }
                                    #endif
                                    Button("Extract Text", systemImage: "text.viewfinder") { Task { await extractText() } }
                                } label: { Label("Image", systemImage: "photo") }
                            }
                            Menu {
                                if item.status == .failed && item.senderDeviceID == engine.identity.id {
                                    Button("Retry", systemImage: "arrow.clockwise") { Task { await engine.retry(item) } }
                                }
                                if let sender = engine.devices.first(where: { $0.id == item.senderDeviceID }) {
                                    Button("Send back to \(sender.name)", systemImage: "arrow.uturn.backward") {
                                        Task {
                                            do { try await engine.resend(item, to: sender.id); feedback = "Sending to \(sender.name)…" }
                                            catch { feedback = error.localizedDescription }
                                        }
                                    }
                                }
                                Button(item.isArchived ? "Move to Inbox" : "Save for Later", systemImage: "bookmark") {
                                    Task { await engine.archive(item, !item.isArchived) }
                                }
                                Button("Delete", systemImage: "trash", role: .destructive) { showDelete = true }
                            } label: { Label("More", systemImage: "ellipsis.circle") }
                        }
                        .buttonStyle(.borderless)
                        .padding(.horizontal, 8)
                    }
                }

                Text("Sent from \(sourceName) · \(item.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.footnote).foregroundStyle(.secondary)
                if let feedback { Text(feedback).font(.footnote).foregroundStyle(.secondary) }
            }
            .padding(24)
            .frame(maxWidth: 700, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(item.kind == .file ? "File" : "Details")
        .task {
            await engine.markRead(item)
            await preparePreview()
        }
        .onDisappear {
            if let exportedURL { Task { await engine.repository.removeExport(exportedURL) } }
        }
        .quickLookPreview($previewURL)
        .sheet(isPresented: $showEventSheet) { EventCreationView(text: item.text ?? item.title) }
        .sheet(isPresented: $showOCR) {
            NavigationStack {
                ScrollView { Text(recognizedText).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding() }
                    .navigationTitle("Text in Image")
                    .toolbar { Button("Done") { showOCR = false } }
            }.frame(minWidth: 350, minHeight: 250)
        }
        .confirmationDialog("Delete this transfer?", isPresented: $showDelete) {
            Button("Delete", role: .destructive) { Task { if await engine.delete(item) { dismiss() } } }
        }
        .confirmationDialog("Decline this transfer?", isPresented: $showDecline) {
            Button("Decline Transfer", role: .destructive) { Task { if await engine.decline(item) { dismiss() } } }
        }
    }

    private var actionTitle: String {
        switch item.kind {
        case .link: "Open in Safari"
        case .location: "Open in Maps"
        case .phone: "Call"
        case .email: "Compose Email"
        case .file, .image: "Open"
        case .event: "Add to Calendar"
        case .code, .text: "Copy Text"
        }
    }

    private func primaryAction() async {
        switch item.kind {
        case .link:
            if let url = item.sourceURL, ["https", "http"].contains(url.scheme?.lowercased() ?? "") { openChecked(url) }
        case .location:
            if let text = item.text, var components = URLComponents(string: "https://maps.apple.com/") {
                components.queryItems = [URLQueryItem(name: "q", value: text)]
                if let url = components.url { openChecked(url) }
            }
        case .phone:
            if let text = item.text, let url = URL(string: "tel:\(text.filter { $0.isNumber || $0 == "+" })") { openChecked(url) }
        case .email:
            if let text = item.text, let url = URL(string: "mailto:\(text)") { openChecked(url) }
        case .file, .image:
            if exportedURL == nil { await preparePreview() }
            previewURL = exportedURL
        case .event:
            showEventSheet = true
        case .text, .code:
            await copyContent()
        }
    }

    private func openChecked(_ url: URL) {
        openURL(url) { accepted in
            if !accepted { feedback = "This device couldn't open that action. You can copy or share the content instead." }
        }
    }

    private func preparePreview() async {
        guard let blobID = item.blobID, !isPreparingPreview else { return }
        isPreparingPreview = true
        defer { isPreparingPreview = false }
        do {
            let url = try await engine.repository.exportBlob(blobID, filename: item.filename ?? item.title)
            if Task.isCancelled { await engine.repository.removeExport(url); return }
            if let old = exportedURL { await engine.repository.removeExport(old) }
            exportedURL = url
            previewIssue = nil
        } catch { previewIssue = DeliveryIssue(error: error) }
    }

    private func copyContent() async {
        if let text = item.text {
            #if os(iOS)
            UIPasteboard.general.string = text
            #else
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            #endif
        } else if item.kind == .image, let blobID = item.blobID,
                  let data = try? await engine.repository.loadBlob(blobID) {
            #if os(iOS)
            UIPasteboard.general.setData(data, forPasteboardType: item.typeIdentifier ?? "public.image")
            #else
            if let image = NSImage(data: data) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([image])
            }
            #endif
        } else if let url = exportedURL {
            #if os(iOS)
            UIPasteboard.general.url = url
            #else
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([url as NSURL])
            #endif
        }
        else { feedback = "Couldn't copy this item. Try opening the file again."; return }
        feedback = "Copied"
    }

    private func extractText() async {
        guard let blobID = item.blobID, let data = try? await engine.repository.loadBlob(blobID) else { return }
        do {
            recognizedText = try await Task.detached(priority: .userInitiated) {
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 3_000
                      ] as CFDictionary) else { throw TossError.invalidContent }
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                try VNImageRequestHandler(cgImage: image).perform([request])
                return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            }.value
            if recognizedText.isEmpty { feedback = "No text found in this image." }
            else { showOCR = true }
        } catch { feedback = "Couldn't read text in this image." }
    }

    #if os(iOS)
    private func saveImageToPhotos() async {
        guard let blobID = item.blobID, let data = try? await engine.repository.loadBlob(blobID) else { return }
        let permission = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard permission == .authorized || permission == .limited else {
            feedback = "Allow Photos access in Settings to save this image."
            return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
            }
            feedback = "Saved to Photos"
        } catch { feedback = "Couldn't save this image." }
    }
    #endif
}

private struct ImagePreview: View {
    let blobID: UUID
    let repository: TransferRepository
    @State private var preview: CGImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let preview { Image(decorative: preview, scale: 1).resizable().scaledToFit() }
            else if failed { Label("Preview unavailable.", systemImage: "photo.badge.exclamationmark").foregroundStyle(.secondary) }
            else { ProgressView("Loading preview…") }
        }
        .frame(maxHeight: 420)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .task {
            guard let data = try? await repository.loadBlob(blobID) else { failed = true; return }
            preview = await Task.detached(priority: .userInitiated) {
                guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil as CGImage? }
                return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 2_048
                ] as CFDictionary)
            }.value
            failed = preview == nil
        }
    }
}

struct DeviceRow: View {
    let device: TrustedDevice
    let online: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(.title3).frame(width: 36).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name).font(.body.weight(.medium))
                Text(online ? "Available nearby" : "Will deliver when available")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: online ? "circle.fill" : "circle.dashed")
                .font(.caption2).foregroundStyle(online ? .green : .secondary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
