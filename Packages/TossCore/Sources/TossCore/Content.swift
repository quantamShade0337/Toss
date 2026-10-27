import Foundation
import UniformTypeIdentifiers
import ImageIO

public struct ClassifiedContent: Sendable {
    public let kind: ContentKind
    public let title: String
    public let subtitle: String
    public let sourceURL: URL?

    public init(kind: ContentKind, title: String, subtitle: String, sourceURL: URL? = nil) {
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.sourceURL = sourceURL
    }
}

public enum ContentClassifier {
    public static func classify(_ input: String) -> ClassifiedContent {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(),
           ["https", "http"].contains(scheme), let host = url.host, !host.isEmpty,
           !text.contains(where: \.isNewline) {
            return ClassifiedContent(kind: .link, title: host, subtitle: text, sourceURL: url)
        }
        if matches(text, #"^[A-Z0-9a-z._%+-]+@[A-Z0-9a-z.-]+\.[A-Za-z]{2,}$"#) {
            return ClassifiedContent(kind: .email, title: text, subtitle: "Email address")
        }
        if matches(text, #"^\+?[0-9][0-9 ()-]{5,}[0-9]$"#) {
            return ClassifiedContent(kind: .phone, title: text, subtitle: "Phone number")
        }
        if text.count < 160 && matches(text, #"(?i)\b(street|st|road|rd|avenue|ave|boulevard|blvd|drive|dr|lane|ln)\b"#)
            && matches(text, #"\d"#) {
            return ClassifiedContent(kind: .location, title: text, subtitle: "Address")
        }
        if text.count < 240 && matches(text, #"(?i)\b(today|tomorrow|monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b"#)
            && matches(text, #"(?i)\b\d{1,2}(:\d{2})?\s*(am|pm)\b"#) {
            return ClassifiedContent(kind: .event, title: text, subtitle: "Possible event")
        }
        if matches(text, #"(?m)^\s*(func|class|struct|import|let|var|def|function|const)\b|[{};].*\n"#) {
            return ClassifiedContent(kind: .code, title: String(text.prefix(70)), subtitle: "Code")
        }
        return ClassifiedContent(kind: .text, title: String(text.prefix(70)), subtitle: "Text")
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
}

public enum FileSafety {
    public static let maximumBytes = 20 * 1_024 * 1_024

    public static func safeFilename(_ input: String) -> String {
        let component = input.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? ""
        let invalid = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: ":/\\\0"))
        let cleaned = component.components(separatedBy: invalid).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "Received file" : String(cleaned.prefix(180))
    }

    public static func validate(_ data: Data, typeIdentifier: String?) throws {
        guard !data.isEmpty else { throw TossError.invalidContent }
        guard data.count <= maximumBytes else { throw TossError.tooLarge }
        if let typeIdentifier {
            guard let declared = UTType(typeIdentifier) else { throw TossError.invalidContent }
            if declared.conforms(to: .image) {
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      CGImageSourceGetCount(source) > 0,
                      let actualID = CGImageSourceGetType(source) as String?,
                      let actual = UTType(actualID), actual.conforms(to: declared),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int,
                      let height = properties[kCGImagePropertyPixelHeight] as? Int,
                      width > 0, height > 0, width <= 20_000, height <= 20_000,
                      Int64(width) * Int64(height) <= 100_000_000 else { throw TossError.invalidContent }
            } else if declared.conforms(to: .pdf) {
                guard data.starts(with: Data("%PDF-".utf8)) else { throw TossError.invalidContent }
            }
        }
    }

    public static func load(_ url: URL) throws -> Data {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maximumBytes else { throw TossError.tooLarge }
        guard let stream = InputStream(url: url) else { throw TossError.invalidContent }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? TossError.invalidContent }
            if count == 0 { break }
            guard data.count + count <= maximumBytes else { throw TossError.tooLarge }
            data.append(contentsOf: buffer.prefix(count))
        }
        try validate(data, typeIdentifier: UTType(filenameExtension: url.pathExtension)?.identifier)
        return data
    }
}

public enum IncomingValidator {
    public static func validate(_ item: TransferItem, data: Data?, senderID: String, receiverID: String) throws {
        guard item.senderDeviceID == senderID, item.receiverDeviceID == receiverID,
              item.createdAt <= .now.addingTimeInterval(300),
              max(item.createdAt, item.scheduledAt ?? item.createdAt) >= .now.addingTimeInterval(-30 * 86_400),
              item.title.count <= 200, item.subtitle.count <= 500,
              item.byteCount >= 0, item.byteCount <= FileSafety.maximumBytes,
              (item.text?.utf8.count ?? 0) <= 1_000_000,
              (item.filename?.count ?? 0) <= 200 else { throw TossError.invalidContent }
        if let url = item.sourceURL {
            guard ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
                throw TossError.invalidContent
            }
        }
        if let data {
            try FileSafety.validate(data, typeIdentifier: item.typeIdentifier)
            guard data.count == item.byteCount, item.kind == .file || item.kind == .image,
                  item.filename != nil, item.text == nil, item.sourceURL == nil else { throw TossError.invalidContent }
            if item.kind == .image {
                guard let typeID = item.typeIdentifier, UTType(typeID)?.conforms(to: .image) == true else {
                    throw TossError.invalidContent
                }
            }
        } else {
            guard item.blobID == nil, let text = item.text, item.byteCount == text.utf8.count else {
                throw TossError.invalidContent
            }
            let classified = ContentClassifier.classify(text)
            guard item.kind == classified.kind, item.sourceURL == classified.sourceURL else {
                throw TossError.invalidContent
            }
        }
    }
}
