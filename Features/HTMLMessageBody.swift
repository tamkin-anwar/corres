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
            // TEMPORARY diagnostic: print every img src Swift actually sees in
            // the source HTML, with no dependency on JS evaluation working at
            // all, so a real report can say whether the markup itself is the
            // problem (missing/malformed src) versus a WKWebView rendering
            // issue. Remove once the root cause is confirmed.
            let srcs = Self.extractImgSrcs(html)
            print("HTMLMessageBody: \(srcs.count) <img> tag(s) found:")
            for src in srcs { print("  - \(src.prefix(120))") }
            // baseURL: nil is a well-documented real-device bug (fine in
            // Simulator): without an origin, WKWebView does not establish a
            // proper security/cookie context, and absolute https:// image
            // fetches can silently fail. This domain is never actually
            // resolved (nothing is loaded from it; the page content comes
            // entirely from loadHTMLString), it exists only to give the page
            // a real https origin.
            webView.loadHTMLString(Self.wrap(html), baseURL: Self.placeholderBaseURL)
        }
    }

    /// Diagnostic only (see above); a simple regex, not a real HTML parser.
    private static func extractImgSrcs(_ html: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"<img[^>]+src=["']([^"']+)["']"#, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        return regex.matches(in: html, range: range).compactMap { match in
            guard let r = Range(match.range(at: 1), in: html) else { return nil }
            return String(html[r])
        }
    }

    private static let placeholderBaseURL = URL(string: "https://mail.corres.app/")

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
            webView.evaluateJavaScript("document.body.scrollHeight") { [weak self] result, error in
                if let error {
                    // TEMPORARY diagnostic: confirms whether allowsContentJavaScript
                    // = false also silently blocks host-triggered evaluateJavaScript
                    // (a real, open question, not previously verified) versus that
                    // restriction being content-script-only as assumed.
                    print("HTMLMessageBody: evaluateJavaScript(scrollHeight) failed: \(error)")
                }
                guard let self, let measured = result as? CGFloat, measured > 0 else { return }
                self.parent.height = measured
            }
            webView.evaluateJavaScript("""
                (function() {
                    var imgs = document.querySelectorAll('img');
                    var out = [];
                    for (var i = 0; i < imgs.length; i++) {
                        out.push(imgs[i].src + ' complete=' + imgs[i].complete + ' naturalWidth=' + imgs[i].naturalWidth);
                    }
                    return out.join('\\n');
                })()
                """) { result, error in
                if let error {
                    print("HTMLMessageBody: img status query failed: \(error)")
                } else if let text = result as? String {
                    print("HTMLMessageBody: img status after load:\n\(text.isEmpty ? "(no <img> elements in DOM)" : text)")
                }
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
