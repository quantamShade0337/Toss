#if DEBUG
import SwiftUI
import TossCore

enum PreviewFixtures {
    static let items: [TransferItem] = [
        TransferItem(senderDeviceID: "mac", receiverDeviceID: "phone", kind: .file,
                     title: "Physics Notes.pdf", subtitle: "2.4 MB", filename: "Physics Notes.pdf",
                     typeIdentifier: "com.adobe.pdf", byteCount: 2_400_000, status: .delivered),
        TransferItem(senderDeviceID: "mac", receiverDeviceID: "phone", kind: .location,
                     title: "313 Orchard Road", subtitle: "Address", text: "313 Orchard Road",
                     byteCount: 16, status: .delivered),
        TransferItem(senderDeviceID: "mac", receiverDeviceID: "phone", kind: .link,
                     title: "Notion — Your connected workspace", subtitle: "notion.so",
                     text: "https://notion.so", sourceURL: URL(string: "https://notion.so"),
                     byteCount: 17, status: .delivered),
        TransferItem(senderDeviceID: "mac", receiverDeviceID: "phone", kind: .image,
                     title: "Photo.heic", subtitle: "3.2 MB", filename: "Photo.heic",
                     typeIdentifier: "public.heic", byteCount: 3_200_000, status: .delivered),
        TransferItem(senderDeviceID: "mac", receiverDeviceID: "phone", kind: .event,
                     title: "Dinner with Ryan tomorrow at 7 PM", subtitle: "Possible event",
                     text: "Dinner with Ryan tomorrow at 7 PM", byteCount: 33, status: .delivered)
    ]
}

#Preview("Transfer rows") {
    List(PreviewFixtures.items) { item in
        TransferRow(item: item, deviceName: "Ethan's MacBook")
    }
}
#endif
