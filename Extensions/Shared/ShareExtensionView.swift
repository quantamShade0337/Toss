import SwiftUI
import TossCore
import UniformTypeIdentifiers
import ImageIO
#if os(iOS)
import UIKit
#else
import AppKit
#endif

enum SharedInput {
    case text(String)
    case data(Data, filename: String, type: String?)
}

enum ShareExtractor {
    static func extract(_ items: [NSExtensionItem]) async throws -> SharedInput {
        let providers = items.compactMap(\.attachments).flatMap { $0 }
        guard let provider = providers.first else { throw TossError.invalidContent }
        for type in [UTType.fileURL, .image, .url, .plainText] where provider.hasItemConformingToTypeIdentifier(type.identifier) {
            let loaded: NSSecureCoding? = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NSSecureCoding?, Error>) in
                provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { value, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: value) }
                }
            }
            if let url = loaded as? URL {
                if url.isFileURL {
                    let data = try await Task.detached(priority: .userInitiated) {
                        try FileSafety.load(url)
                    }.value
                    return .data(data, filename: url.lastPathComponent,
                                 type: UTType(filenameExtension: url.pathExtension)?.identifier)
                }
                return .text(url.absoluteString)
            }
            if let string = loaded as? String { return .text(string) }
            if let data = loaded as? Data {
                if type == .plainText, let text = String(data: data, encoding: .utf8) { return .text(text) }
                if type == .image,
                   let source = CGImageSourceCreateWithData(data as CFData, nil),
                   let actualID = CGImageSourceGetType(source) as String?, let actual = UTType(actualID) {
                    return .data(data, filename: "Shared Image.\(actual.preferredFilenameExtension ?? "img")",
                                 type: actual.identifier)
                }
                return .data(data, filename: "Shared File", type: nil)
            }
            #if os(iOS)
            if let image = loaded as? UIImage, let data = image.jpegData(compressionQuality: 0.9) {
                return .data(data, filename: "Shared Image.jpg", type: UTType.jpeg.identifier)
            }
            #else
            if let image = loaded as? NSImage, let tiff = image.tiffRepresentation {
                return .data(tiff, filename: "Shared Image.tiff", type: UTType.tiff.identifier)
            }
            #endif
        }
        throw TossError.invalidContent
    }
}

struct ShareExtensionView: View {
    let items: [NSExtensionItem]
    let finish: () -> Void
    @State private var engine: TossEngine?
    @State private var input: SharedInput?
    @State private var status: String?
    @State private var sending = false
    @State private var completed = false
    @State private var loadAttempt = 0

    var body: some View {
        NavigationStack {
            Group {
                if completed {
                    ContentUnavailableView {
                        Label(status ?? "Saved", systemImage: "checkmark.circle")
                    } description: {
                        Text("Open Toss to send queued items. Saved items are in Later on this device.")
                    } actions: {
                        Button("Done") { finish() }.buttonStyle(.borderedProminent)
                    }
                } else if let engine, let input {
                    List {
                        Section {
                            Label(inputTitle(input), systemImage: inputSymbol(input))
                                .lineLimit(2)
                        }
                        Section("Send to") {
                            if engine.devices.isEmpty { Text("Connect a device in Toss first.").foregroundStyle(.secondary) }
                            ForEach(engine.devices) { device in
                                Button { Task { await send(input, to: device, engine: engine) } } label: {
                                    HStack {
                                        Image(systemName: "desktopcomputer").frame(width: 30)
                                        VStack(alignment: .leading) {
                                            Text(device.name)
                                            Text("Will deliver when available")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }.disabled(sending)
                            }
                        }
                        Section {
                            Button("Save for Later", systemImage: "bookmark") {
                                Task { await save(input, engine: engine) }
                            }.disabled(sending)
                        }
                        if let status { Section { Text(status).foregroundStyle(.secondary) } }
                    }
                } else if let status {
                    ContentUnavailableView {
                        Label("Couldn't prepare this item", systemImage: "exclamationmark.circle")
                    } description: { Text(status) } actions: {
                        Button("Try Again") { self.status = nil; engine = nil; loadAttempt += 1 }
                        Button("Close") { finish() }
                    }
                } else { ProgressView("Preparing…") }
            }
            .navigationTitle("Toss")
            .toolbar { Button("Cancel") { finish() } }
        }
        .task(id: loadAttempt) {
            guard engine == nil else { return }
            do {
                let created = try TossEngine()
                engine = created
                input = try await ShareExtractor.extract(items)
                await created.refresh()
            } catch { status = DeliveryIssue(error: error).guidance }
        }
    }

    private func inputTitle(_ input: SharedInput) -> String {
        switch input {
        case .text(let text): String(text.prefix(110))
        case .data(_, let filename, _): filename
        }
    }

    private func inputSymbol(_ input: SharedInput) -> String {
        switch input { case .text: "text.alignleft"; case .data: "doc" }
    }

    private func send(_ input: SharedInput, to device: TrustedDevice, engine: TossEngine) async {
        guard !sending else { return }
        sending = true
        do {
            switch input {
            case .text(let text): _ = try await engine.sendText(text, to: device.id)
            case .data(let data, let filename, let type):
                _ = try await engine.sendData(data, filename: filename, typeIdentifier: type, to: device.id)
            }
            status = "Queued for \(device.name)"
            completed = true
        } catch { status = DeliveryIssue(error: error).guidance }
        sending = false
    }

    private func save(_ input: SharedInput, engine: TossEngine) async {
        guard !sending else { return }
        sending = true
        do {
            switch input {
            case .text(let text): try await engine.saveLocally(text: text)
            case .data(let data, let filename, let type):
                try await engine.saveLocally(data: data, filename: filename, typeIdentifier: type)
            }
            status = "Saved for later"
            completed = true
        } catch { status = DeliveryIssue(error: error).guidance; sending = false }
    }
}
