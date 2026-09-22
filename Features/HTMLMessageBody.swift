import SwiftUI
import WebKit

/// Renders a message's real HTML body. JavaScript is always disabled: mail
/// content is untrusted (ADR 002/006) and never needs to execute code to
/// display correctly. Every link tap opens in the system browser, never
/// inline, after validating the scheme is http/https (blocks a tapped
/// javascript: or arbitrary custom-scheme link from silently doing something
/// unexpected). Remote `<img>` sources are blocked by default per ADR 006
/// (marketing mail routinely uses a 1x1 remote image purely to log that the
/// message was opened); `cid:`-referenced images are inlined as `data:` URIs
/// by GmailAPIClient before this view ever sees the HTML, so they are real
/// message content, not a remote fetch, and are unaffected by this.
struct HTMLMessageBody: UIViewRepresentable {
    let html: String
    @Binding var height: CGFloat
    var blockRemoteImages = true

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.scrollView.isScrollEnabled = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        let processed = blockRemoteImages ? Self.blockingRemoteImages(in: html) : html
        if context.coordinator.lastLoadedHTML != processed {
            context.coordinator.lastLoadedHTML = processed
            // baseURL: nil is a well-documented real-device bug (fine in
            // Simulator): without an origin, WKWebView does not establish a
            // proper security/cookie context, and absolute https:// image
            // fetches can silently fail. This domain is never actually
            // resolved (nothing is loaded from it; the page content comes
            // entirely from loadHTMLString), it exists only to give the page
            // a real https origin.
            webView.loadHTMLString(Self.wrap(processed), baseURL: Self.placeholderBaseURL)
        }
    }

    private static let placeholderBaseURL = URL(string: "https://mail.corres.app/")

    /// How many `<img>` tags in `html` point at a remote http(s) URL, so a
    /// caller can show a "N images blocked" banner without needing its own
    /// WKWebView instance to find out.
    static func remoteImageCount(in html: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: remoteImgSrcPattern, options: [.caseInsensitive]) else { return 0 }
        return regex.numberOfMatches(in: html, range: NSRange(html.startIndex..., in: html))
    }

    /// Replaces every remote `<img>` source with an inline transparent pixel,
    /// so no network request is made at all until the user chooses to load
    /// images. Deliberately narrow in scope (only `<img src>`, not CSS
    /// `background-image`): that covers the overwhelming majority of real
    /// tracking pixels, at a fraction of the false-positive risk of rewriting
    /// arbitrary inline styles.
    private static func blockingRemoteImages(in html: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: remoteImgSrcPattern, options: [.caseInsensitive]) else { return html }
        let range = NSRange(html.startIndex..., in: html)
        return regex.stringByReplacingMatches(in: html, options: [], range: range,
                                               withTemplate: "$1$2\(transparentPixelDataURI)$2")
    }

    private static let remoteImgSrcPattern = #"(<img\b[^>]*\bsrc\s*=\s*)(["'])https?://[^"']*\2"#
    private static let transparentPixelDataURI = "data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw=="

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// Wraps the raw body fragment with a stylesheet approximating Corres's
    /// own reading typography, since the sender's HTML doesn't know it.
    ///
    /// Deliberately does NOT force `width=device-width` or clamp `<table>`/
    /// `<img>` to `max-width: 100%`. Real marketing HTML is built for a fixed
    /// desktop-style width (600-1000pt), with font sizes and column widths
    /// chosen for that width; clamping only the table's own width while
    /// leaving those font sizes and inner element widths untouched breaks
    /// their proportions relative to each other; that was the actual cause
    /// of oversized, cut-off headline text and broken spacing seen in
    /// testing, not a loading or image bug. `width=1024` lets the page lay
    /// out at (or near) its natural width like a real mail client does; the
    /// Coordinator then measures that natural size and shrinks the whole
    /// rendered page down uniformly (see `didFinish`), the same "desktop
    /// site" viewport technique Safari uses for non-mobile-responsive pages,
    /// which preserves every element's size relative to every other one.
    private static func wrap(_ html: String) -> String {
        """
        <html><head><meta name="viewport" content="width=1024">
        <style>
        body { font: -apple-system-body; font-size: 17px; line-height: 1.5; color: -apple-system-label;
               margin: 0; padding: 0; word-wrap: break-word; -webkit-text-size-adjust: 100%;
               background: transparent; }
        a { color: #274D61; }
        </style></head><body>\(html)</body></html>
        """
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: HTMLMessageBody
        var lastLoadedHTML: String?
        init(_ parent: HTMLMessageBody) { self.parent = parent }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // allowsContentJavaScript = false only restricts content-embedded
            // <script> execution; this host-triggered evaluateJavaScript call
            // is unaffected (confirmed on-device: it reliably returns a value).
            webView.evaluateJavaScript("[document.body.scrollWidth, document.body.scrollHeight]") { [weak self] result, _ in
                guard let self, let dimensions = result as? [Double], dimensions.count == 2,
                      let contentWidth = dimensions.first, let contentHeight = dimensions.last,
                      contentWidth > 0, contentHeight > 0 else { return }
                let viewportWidth = webView.bounds.width
                // Uniformly shrink the whole rendered page to fit, rather
                // than the earlier per-element CSS clamping that broke
                // proportions (see wrap()'s doc comment). Never scale a
                // narrower-than-device email UP; only shrink an oversized one.
                let scale = viewportWidth > 0 && contentWidth > viewportWidth ? viewportWidth / contentWidth : 1
                webView.scrollView.minimumZoomScale = scale
                webView.scrollView.maximumZoomScale = scale
                webView.scrollView.zoomScale = scale
                self.parent.height = contentHeight * scale
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            print("HTMLMessageBody: navigation failed: \(error)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            print("HTMLMessageBody: provisional navigation failed: \(error)")
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                UIApplication.shared.open(url)
            }
            decisionHandler(.cancel)
        }
    }
}
