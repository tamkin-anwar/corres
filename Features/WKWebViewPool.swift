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
    private let processPool = WKProcessPool()
    private let poolSize = 2

    private init() {}

    /// Called once from CorresApp's launch task, before any await, off the
    /// interaction path entirely: pre-creates the pool itself (not one
    /// separate throwaway instance) so the very first real conversation
    /// also gets to borrow an already-warm webview.
    func prewarm() {
        guard available.isEmpty else { return }
        for _ in 0..<poolSize {
            let webView = makeWebView()
            webView.loadHTMLString("<html></html>", baseURL: nil)
            available.append(webView)
        }
    }

    func dequeue() -> WKWebView {
        available.popLast() ?? makeWebView()
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
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
        webView.scrollView.setContentOffset(.zero, animated: false)
        webView.scrollView.minimumZoomScale = 1
        webView.scrollView.maximumZoomScale = 1
        webView.scrollView.zoomScale = 1
        webView.alpha = 1
        // Extras beyond poolSize are simply let go rather than grown into
        // an unbounded pool: per the research above, each live instance is
        // a real, non-trivial OS resource, not something to hoard freely.
        guard available.count < poolSize else { return }
        available.append(webView)
    }

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.processPool = processPool
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.suppressesIncrementalRendering = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        return webView
    }
}
