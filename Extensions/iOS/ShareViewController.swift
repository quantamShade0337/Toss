import SwiftUI
import UIKit

final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let view = ShareExtensionView(items: extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []) {
            self.extensionContext?.completeRequest(returningItems: nil)
        }
        let host = UIHostingController(rootView: view)
        addChild(host)
        host.view.frame = self.view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        self.view.addSubview(host.view)
        host.didMove(toParent: self)
    }
}
