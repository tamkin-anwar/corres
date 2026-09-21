import SwiftUI
import WebKit

/// Renders a message's real HTML body. JavaScript is always disabled: mail
/// content is untrusted (ADR 002/006) and never needs to execute code to
/// display correctly. Every link tap opens in the system browser, never
/// inline, after validating the scheme is http/https (blocks a tapped
/// javascript: or arbitrary custom-scheme link from silently doing something
/// unexpected). Remote image loading is NOT yet blocked by default; ADR 006
/// calls for that, and it is a documented, deliberate follow-up, not an oversight.
struct HTMLMessageBody: UIViewRepresentable {
    let html: String
    @Binding var height: CGFloat

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
        if context.coordinator.lastLoadedHTML != html {
            context.coordinator.lastLoadedHTML = html
            webView.loadHTMLString(Self.wrap(html), baseURL: nil)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// Wraps the raw body fragment with a stylesheet approximating Corres's
    /// own reading typography, since the sender's HTML doesn't know it.
    private static func wrap(_ html: String) -> String {
        """
        <html><head><meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        body { font: -apple-system-body; font-size: 17px; line-height: 1.5; color: -apple-system-label;
               margin: 0; padding: 0; word-wrap: break-word; -webkit-text-size-adjust: 100%;
               background: transparent; }
        img { max-width: 100%; height: auto; }
        a { color: #274D61; }
        table { max-width: 100% !important; }
        </style></head><body>\(html)</body></html>
        """
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: HTMLMessageBody
        var lastLoadedHTML: String?
        init(_ parent: HTMLMessageBody) { self.parent = parent }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("document.body.scrollHeight") { [weak self] result, _ in
                guard let self, let measured = result as? CGFloat, measured > 0 else { return }
                self.parent.height = measured
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
