import AppKit
import SwiftUI

final class ShareViewController: NSViewController {
    override func loadView() {
        let view = ShareExtensionView(items: extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []) {
            self.extensionContext?.completeRequest(returningItems: nil)
        }
        self.view = NSHostingView(rootView: view)
    }
}
