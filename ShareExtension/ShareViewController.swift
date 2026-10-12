import SwiftUI
import UIKit

/// The Share sheet's "Corres": writes and sends the email right there,
/// as Mail and Gmail do, instead of opening the app.
final class ShareViewController: UIViewController {
    private let composer = ShareComposer()

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ShareComposeView(composer: composer) { [weak self] completed in
            self?.finish(completed)
        })
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)
        // Swiping the sheet down asks first, like Compose, once something's written.
        isModalInPresentation = true

        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        Task { await composer.load(items) }
    }

    private func finish(_ completed: Bool) {
        if completed {
            extensionContext?.completeRequest(returningItems: nil)
        } else {
            extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
        }
    }
}
