import WebKit

/// A small pool of reusable `WKWebView` instances, shared across every
/// `HTMLMessageBody` on screen. Researched, not assumed: creating a fresh
/// WKWebView is one of the heaviest actions an app can take on iOS, since
/// each instance not sharing a `WKProcessPool` can spin up several of its
/// own OS processes; reusing an existing instance (clearing and reloading
/// content, not deleting and recreating) is the established fix. This is
/// the cost that remains after `prewarm()` addresses the very first
/// cold start: every conversation opened after that also borrows an
/// already-live webview instead of paying to create a new one.
@MainActor
final class WKWebViewPool {
    static let shared = WKWebViewPool()

    private var available: [WKWebView] = []
    /// Each webview's route for its email's size reports, retargeted to
    /// whichever message borrows it (see `HTMLMessageBody.sizingScript`).
    private var routers: [ObjectIdentifier: SizeMessageRouter] = [:]
    private let processPool = WKProcessPool()
    private let poolSize = 2

    private init() {}

    /// Called once from CorresApp's launch task, a moment after the first
    /// screen settles: pre-creates the pool itself (not one separate
    /// throwaway instance) so the very first real conversation also gets
    /// to borrow an already-warm webview.
    func prewarm() async {
        guard available.isEmpty else { return }
        for _ in 0..<poolSize {
            let webView = makeWebView()
            webView.loadHTMLString("<html></html>", baseURL: nil)
            available.append(webView)
            // One at a time, letting touches through in between.
            await Task.yield()
        }
    }

    func dequeue() -> WKWebView {
        available.popLast() ?? makeWebView()
    }

    func sizeRouter(for webView: WKWebView) -> SizeMessageRouter {
        if let router = routers[ObjectIdentifier(webView)] { return router }
        // Not made by the pool (shouldn't happen); give it a route anyway.
        return install(on: webView)
    }

    /// Resets everything a borrower could have left behind: a stale
    /// delegate would otherwise keep firing callbacks at a coordinator that
    /// no longer owns this instance (delegates are `weak`, so this isn't a
    /// retain-cycle risk, but a correctness one); stale content, scroll
    /// position, and zoom scale would otherwise flash briefly the next time
    /// this instance is reused, before its new content's own measurement
    /// pass corrects them.
    func enqueue(_ webView: WKWebView) {
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        routers[ObjectIdentifier(webView)]?.target = nil
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
        webView.scrollView.setContentOffset(.zero, animated: false)
        webView.scrollView.setZoomScale(1, animated: false)
        webView.scrollView.isScrollEnabled = false
        webView.alpha = 1
        // Extras beyond poolSize are simply let go rather than grown into
        // an unbounded pool: per the research above, each live instance is
        // a real, non-trivial OS resource, not something to hoard freely.
        guard available.count < poolSize else {
            routers[ObjectIdentifier(webView)] = nil
            webView.configuration.userContentController.removeAllScriptMessageHandlers()
            return
        }
        available.append(webView)
    }

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.processPool = processPool
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        // Addresses, phone numbers, dates, flights, tracking numbers and
        // bare web addresses in the text become tappable, found on this
        // iPhone the way Mail finds them.
        configuration.dataDetectorTypes = [.address, .phoneNumber, .calendarEvent, .link, .flightNumber, .trackingNumber]
        // Off: on, nothing painted until every image had loaded, so an
        // image-heavy email sat blank for seconds. A reused webview's old
        // content is still never shown (HTMLMessageBody keeps it hidden
        // until the new email's first size report).
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        // Zoomed in, the email pans sideways inside itself; up and down
        // always scrolls the conversation (see HTMLMessageBody.Coordinator).
        webView.scrollView.alwaysBounceVertical = false
        webView.scrollView.isDirectionalLockEnabled = true
        install(on: webView)
        return webView
    }

    @discardableResult
    private func install(on webView: WKWebView) -> SizeMessageRouter {
        let router = SizeMessageRouter()
        router.webView = webView
        let controller = webView.configuration.userContentController
        controller.addUserScript(WKUserScript(source: HTMLMessageBody.sizingScript, injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: true, in: .defaultClient))
        controller.add(router, contentWorld: .defaultClient, name: "corresSize")
        routers[ObjectIdentifier(webView)] = router
        return router
    }
}

/// Hands an email's size reports to the message currently showing in the
/// webview. Weak both ways: the content controller holds this strongly.
@MainActor
final class SizeMessageRouter: NSObject, WKScriptMessageHandler {
    weak var target: HTMLMessageBody.Coordinator?
    weak var webView: WKWebView?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let load = (body["load"] as? NSNumber)?.intValue,
              let height = (body["height"] as? NSNumber)?.doubleValue else { return }
        target?.receiveSize(load: load, height: CGFloat(height), webView: webView)
    }
}
