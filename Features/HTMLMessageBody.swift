import SwiftUI
import UIKit
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
    @Environment(\.colorScheme) private var colorScheme

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebViewPool.shared.dequeue()
        webView.navigationDelegate = context.coordinator
        return webView
    }

    /// Returns the instance to the shared pool instead of letting it
    /// deallocate, so the next conversation opened borrows an already-live
    /// webview rather than paying to create a new one (see WKWebViewPool).
    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        WKWebViewPool.shared.enqueue(webView)
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        // Set unconditionally, even when the guard below skips a reload:
        // WKWebView has no knowledge of the app's own light/dark mode on
        // its own, and CSS system colors like `-apple-system-label`
        // (wrap()'s own stylesheet) resolve against the webview's OWN
        // interface style, which defaults to light, not the app's. With
        // `wrap()`'s `background: transparent` letting Corres's dark
        // canvas show through underneath, the result was near-black text
        // on a near-black background: real mail rendered essentially
        // unreadable, reported directly against a real reply. Pooled
        // instances (WKWebViewPool) make this worse, not better: a reused
        // webview can carry a stale style into a differently-styled
        // conversation, so this can't just be set once at creation.
        // A designed email (its own backgrounds and colours) is shown as its
        // sender made it, on its own white card, the way Mail does: forcing
        // light text onto it in Dark mode put white text on its white
        // tables. Only plain mail from people is adapted to Dark mode.
        let designed = Self.isDesigned(html)
        webView.overrideUserInterfaceStyle = designed ? .light : (colorScheme == .dark ? .dark : .light)
        // Checked against the raw inputs, not the processed/wrapped output:
        // SwiftUI re-invokes updateUIView on any state change anywhere this
        // view observes (e.g. an unrelated background sync mutating
        // store.threads), not only when html/blockRemoteImages actually
        // changed. Guarding here first, before ever touching
        // blockingRemoteImages's regex work, means an unrelated re-render
        // costs nothing instead of re-running a full-body regex scan.
        guard context.coordinator.lastHTML != html || context.coordinator.lastBlockRemoteImages != blockRemoteImages else { return }
        context.coordinator.lastHTML = html
        context.coordinator.lastBlockRemoteImages = blockRemoteImages
        // Invalidates any re-measurement still scheduled from a previous
        // load on this same (possibly pooled/reused) webview instance; see
        // Coordinator.loadGeneration.
        context.coordinator.loadGeneration += 1
        var processed = blockRemoteImages ? Self.blockingRemoteImages(in: html) : html
        processed = Self.strippingEmbeddedViewportMeta(processed)
        // Hidden until didFinish: a pooled instance still shows whatever it
        // was last displaying until the new load actually finishes, and
        // revealing immediately would flash that stale content for a frame.
        webView.alpha = 0
        // baseURL: nil is a well-documented real-device bug (fine in
        // Simulator): without an origin, WKWebView does not establish a
        // proper security/cookie context, and absolute https:// image
        // fetches can silently fail. This domain is never actually
        // resolved (nothing is loaded from it; the page content comes
        // entirely from loadHTMLString), it exists only to give the page
        // a real https origin.
        webView.loadHTMLString(Self.wrap(processed, adaptsToDark: !designed), baseURL: Self.placeholderBaseURL)
    }

    private static let placeholderBaseURL = URL(string: "https://mail.corres.app/")

    /// How many `<img>` tags in `html` point at a remote http(s) URL, so a
    /// caller can show a "N images blocked" banner without needing its own
    /// WKWebView instance to find out.
    static func remoteImageCount(in html: String) -> Int {
        guard let regex = remoteImgSrcRegex else { return 0 }
        return regex.numberOfMatches(in: html, range: NSRange(html.startIndex..., in: html))
    }

    /// How many of those remote images are tracking pixels: an image
    /// declared 0–2px in either dimension (the defining shape of an open
    /// tracker), or served from a known email-analytics host. A lower bound,
    /// not a guarantee; every remote image is blocked either way.
    static func trackerCount(in html: String) -> Int {
        guard let tagRegex = imgTagRegex else { return 0 }
        let range = NSRange(html.startIndex..., in: html)
        return tagRegex.matches(in: html, range: range).reduce(0) { count, match in
            guard let tagRange = Range(match.range, in: html) else { return count }
            let tag = html[tagRange].lowercased()
            guard tag.contains("http") else { return count }
            let tiny = tag.range(of: #"\b(width|height)\s*=\s*["']?[0-2](px)?["'\s>/]"#, options: .regularExpression) != nil
                || tag.range(of: #"(width|height)\s*:\s*[0-2]px"#, options: .regularExpression) != nil
                || tag.contains("display:none") || tag.contains("display: none")
            let knownHost = trackerHosts.contains { tag.contains($0) }
            return count + (tiny || knownHost ? 1 : 0)
        }
    }

    private static let imgTagRegex = try? NSRegularExpression(pattern: #"<img\b[^>]*>"#, options: [.caseInsensitive])
    /// Common open-tracking hosts used by marketing and sales email tools.
    private static let trackerHosts = ["/open.", "/o.gif", "/track/open", "/wf/open", "pixel.", "/pixel",
                                       "mailtrack", "list-manage.com/track", "sendgrid.net/wf", "mandrillapp.com/track",
                                       "hubspotemail", "t.hubspot", "mixmax", "superhuman.com", "yesware", "bananatag",
                                       "streak.com", "mailchimp.com/track", "ct.sendgrid", "track.customer.io"]

    /// Replaces every remote `<img>` source with an inline transparent pixel,
    /// so no network request is made at all until the user chooses to load
    /// images. Deliberately narrow in scope (only `<img src>`, not CSS
    /// `background-image`): that covers the overwhelming majority of real
    /// tracking pixels, at a fraction of the false-positive risk of rewriting
    /// arbitrary inline styles.
    private static func blockingRemoteImages(in html: String) -> String {
        guard let regex = remoteImgSrcRegex else { return html }
        let range = NSRange(html.startIndex..., in: html)
        return regex.stringByReplacingMatches(in: html, options: [], range: range,
                                               withTemplate: "$1$2\(transparentPixelDataURI)$2")
    }

    /// Compiled once, not per call: NSRegularExpression pattern compilation
    /// is real, non-trivial work, and both call sites above could otherwise
    /// run it on every SwiftUI re-render (`remoteImageCount` is called
    /// directly from ConversationView's body).
    private static let remoteImgSrcRegex = try? NSRegularExpression(
        pattern: #"(<img\b[^>]*\bsrc\s*=\s*)(["'])https?://[^"']*\2"#, options: [.caseInsensitive])
    private static let transparentPixelDataURI = "data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw=="

    /// Real HTML mail bodies routinely carry their own
    /// `<meta name="viewport" ...>` (boilerplate from whatever template
    /// built them, often with `user-scalable=no`/`maximum-scale=1` mixed
    /// in), even though `html` here is only ever a body fragment, not a
    /// full document. WebKit's HTML parser still finds and honors a
    /// `<meta>` tag wherever it appears, so a sender's stray one can
    /// silently win over `wrap()`'s own tag (added second, after the
    /// sender's content) and interfere with the zoom-scale Corres manages
    /// itself (`measureAndScale`, below). Stripped unconditionally so
    /// `wrap()`'s own tag is always the one that actually applies,
    /// regardless of what value the sender's own tag would have set.
    private static let embeddedViewportMetaRegex = try? NSRegularExpression(
        pattern: #"<meta\b[^>]*\bname\s*=\s*["']viewport["'][^>]*>"#, options: [.caseInsensitive])

    private static func strippingEmbeddedViewportMeta(_ html: String) -> String {
        guard let regex = embeddedViewportMetaRegex else { return html }
        let range = NSRange(html.startIndex..., in: html)
        return regex.stringByReplacingMatches(in: html, options: [], range: range, withTemplate: "")
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// Wraps the raw body fragment with a stylesheet approximating Corres's
    /// own reading typography, since the sender's HTML doesn't know it.
    ///
    /// `width=device-width`, not a fixed `width=1024`: a real, reported
    /// regression from the earlier fixed-width approach was a genuinely
    /// simple, short reply (a couple of lines of plain text, no marketing
    /// layout at all) rendering at a fraction of its intended font size.
    /// The cause: a block-level `<body>` with no explicit width of its own
    /// fills its *containing block*, regardless of how little text is
    /// actually inside it, so forcing `width=1024` made `scrollWidth`
    /// measure ~1024 even for two lines of "Hello", and the shrink-to-fit
    /// math (`measureAndScale`, below) divided the whole page, text
    /// included, down to a small fraction of size for content that never
    /// needed to shrink at all.
    ///
    /// This still correctly handles real wide marketing HTML (fixed-width
    /// tables/images sized in raw pixels, not percentages): those don't
    /// shrink to fit `device-width` just because the viewport meta says
    /// so, they overflow it outright, and `scrollWidth` reports that real
    /// overflow (the full extent including anything sticking out past the
    /// viewport, not just the viewport's own width) regardless of which
    /// width the viewport meta requested. `measureAndScale`'s own
    /// `contentWidth > viewportWidth` check already only shrinks when
    /// there's real overflow to correct; the earlier bug was that
    /// forcing `width=1024` manufactured false overflow for content that
    /// never had any, not a flaw in that check itself.
    /// Mail that sets its own look: background colours, colour on its
    /// text, or a style sheet (marketing, receipts, notifications, and
    /// mail from Outlook). Plain mail from Gmail or Mail has none of these.
    static func isDesigned(_ html: String) -> Bool {
        let lower = html.lowercased()
        return lower.range(of: #"bgcolor\s*=|background(-color)?\s*:\s*(#|rgb|white)|<style[\s>]"#,
                           options: .regularExpression) != nil
    }

    private static func wrap(_ html: String, adaptsToDark: Bool = true) -> String {
        guard !adaptsToDark else { return wrapAdaptive(html) }
        // As the sender designed it: light only, on white, their colours.
        return wrapAdaptive(html)
            .replacingOccurrences(of: ":root { color-scheme: light dark; }",
                                  with: ":root { color-scheme: light only; } html, body { background: #FFFFFF !important; }")
            .replacingOccurrences(of: #"@media \(prefers-color-scheme: dark\) \{[\s\S]*?\n        \}\n"#,
                                  with: "", options: .regularExpression)
    }

    private static func wrapAdaptive(_ html: String) -> String {
        """
        <html><head><meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        :root { color-scheme: light dark; }
        html, body { overflow-x: hidden; }
        body { font: -apple-system-body; font-size: 17px; line-height: 1.5; color: #141312 !important;
               margin: 0; padding: 0; word-wrap: break-word; -webkit-text-size-adjust: 100%;
               background: transparent; }
        a { color: #2F5D9E; }
        /* The actual fix for wide marketing HTML, researched against what
           real mail clients do (Apple Mail included, both WebKit-based):
           force every table/image to reflow to the viewport natively,
           rather than measuring the rendered width in JS after the fact and
           visually shrinking the whole page with a view-level zoom
           (`Coordinator.measureAndScale`, below). A multi-column product
           grid built from fixed-pixel `<td width="...">` cells (routine in
           real marketing templates, confirmed against a real UNIQLO email
           reported directly) doesn't reliably get caught by that
           measure-then-zoom approach once real images finish loading
           asynchronously after the initial measurement, and can overflow
           the right edge instead of reflowing, which is exactly the "breaks
           up the email" bug reported against it, contrasted screenshot-by-
           screenshot with Apple Mail's own clean, evenly-split rendering of
           the identical email. `!important` throughout: a sender's own
           inline `width` attribute (not just a CSS `width` property, which
           `!important` alone doesn't override) otherwise wins over this.
           `measureAndScale`'s JS-measured zoom stays as a backstop for
           whatever this doesn't catch (unbreakable long text in a `<pre>`,
           for instance), but should rarely need to actually shrink
           anything now that width overflow is handled at the CSS layer
           instead. */
        /* Measured, not viewport-sized: emails that make their wrapper
           "full screen" (height: 100%, min-height: 100vh) grew every time
           the view grew to fit them, leaving an endless blank tail below
           the message. Their height comes from their content instead. */
        html, body { height: auto !important; min-height: 0 !important; }
        #corres-root { display: flow-root; }
        [height="100%"], [style*="height:100%"], [style*="height: 100%"], [style*="vh"] {
          height: auto !important; min-height: 0 !important; }
        table { max-width: 100% !important; }
        td, th { max-width: 100% !important; }
        img { max-width: 100% !important; height: auto !important; }
        @media (prefers-color-scheme: dark) {
          /* `!important`, deliberately: real mail HTML (Gmail's own quoted-
             reply markup included) routinely sets its own inline `color`
             on individual elements, which would otherwise win over a plain
             `body` rule regardless of dark mode. An `!important` author
             rule is the one thing that outranks a non-important inline
             style in CSS's cascade, so this is what actually makes body
             text legible instead of only working when nothing in the
             sender's own HTML happens to set a color. Relying on the
             literal hex pair here rather than the `-apple-system-label`
             keyword this used before: that keyword's resolution inside an
             offline `loadHTMLString` page (no real origin, no live
             `prefers-color-scheme` media query support confirmed) turned
             out not to reliably track `overrideUserInterfaceStyle` the way
             assumed, confirmed unreadable on a real device even after
             setting it; `prefers-color-scheme` plus real color values is
             the standards-based mechanism actually documented to respect
             `overrideUserInterfaceStyle`. */
          body { color: #F2F3F5 !important; }
          a { color: #8FB4E8; }
        }
        </style></head><body><div id="corres-root">\(html)</div></body></html>
        """
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: HTMLMessageBody
        var lastHTML: String?
        var lastBlockRemoteImages: Bool?
        init(_ parent: HTMLMessageBody) { self.parent = parent }

        /// A generation counter, bumped every time a fresh load starts
        /// (`updateUIView`), so a re-measurement scheduled for an earlier
        /// load can recognize it's stale (the webview has since been reused
        /// for a different conversation, borrowed back from the pool) and
        /// bail out instead of stomping a newer conversation's correct size
        /// with a late measurement of the previous one's.
        var loadGeneration = 0

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let generation = loadGeneration
            Task { @MainActor [weak self, weak webView] in
                guard let self, let webView else { return }
                await self.measureAndScale(webView, generation: generation, revealWhenDone: true)
                await self.pollUntilStable(webView, generation: generation)
            }
        }

        /// Real marketing HTML routinely finishes its main-frame navigation
        /// before every image has actually finished loading (a slow remote
        /// asset over a real, possibly slow connection, or a CSS
        /// `background-image`, neither of which reliably gates the
        /// navigation "finish" event the way a plain `<img src>` does).
        /// Measuring only once at `didFinish` freezes the shrink-to-fit
        /// scale and the WKWebView's own height against a page that then
        /// grows taller a moment later once those finish — and because
        /// `WKWebViewPool` deliberately disables the webview's own internal
        /// scrolling (content is meant to scroll as one continuous page
        /// with everything around it, not in a nested scroll view), any
        /// growth past that locked-in height is silently, invisibly
        /// clipped with no way to scroll and see the rest. Reported
        /// directly against a real, image-heavy marketing email on a real
        /// device: the content visibly stopped mid-image.
        ///
        /// A *fixed* number of re-measurements at fixed delays (this used
        /// to do two, at 350ms/1000ms after `didFinish`) is still only a
        /// guess at how long images take, and a dense email's images can
        /// easily take longer than that on a slower connection. Polls
        /// instead, at a steadily widening interval, until two consecutive
        /// measurements agree within a point (nothing is still loading) or
        /// a generous ~10-second cap is reached (a genuinely stuck remote
        /// resource must not poll forever). A short, fast email with
        /// nothing left to load stabilizes and stops after the very first
        /// check; a slow one keeps checking, without wastefully polling at
        /// a fixed high frequency the whole time.
        private func pollUntilStable(_ webView: WKWebView, generation: Int) async {
            var lastHeight: CGFloat?
            for stepMs in Self.pollIntervalsMs {
                try? await Task.sleep(for: .milliseconds(stepMs))
                guard generation == loadGeneration else { return }
                let measured = await measureAndScale(webView, generation: generation, revealWhenDone: false)
                guard let measured else { continue }
                if let lastHeight, abs(measured - lastHeight) < 1 { return }
                lastHeight = measured
            }
        }

        /// Widening on purpose: a page still actively loading images checks
        /// again soon; one that's taking a while backs off instead of
        /// polling needlessly often while it waits. Sums to just under 10
        /// seconds of total worst-case polling.
        private static let pollIntervalsMs = [150, 200, 300, 450, 650, 900, 1200, 1600, 2000, 2500]

        @discardableResult
        private func measureAndScale(_ webView: WKWebView, generation: Int, revealWhenDone: Bool) async -> CGFloat? {
            // allowsContentJavaScript = false only restricts content-embedded
            // <script> execution; this host-triggered evaluateJavaScript call
            // is unaffected (confirmed on-device: it reliably returns a value).
            // The content's own height, from a wrapper around it, rather
            // than the body's scrollHeight, which is never less than the
            // view itself and so could only ever grow.
            let result = try? await webView.evaluateJavaScript("""
                (() => { const root = document.getElementById('corres-root');
                  return [document.body.scrollWidth,
                          root ? Math.ceil(root.getBoundingClientRect().height) : document.body.scrollHeight]; })()
                """)
            // Reveal unconditionally on the first pass, even if measurement
            // below fails: updateUIView hid this webview (alpha 0) to avoid
            // flashing a pooled instance's stale previous content, and it
            // must not stay invisible forever regardless of what sizing does.
            if revealWhenDone { UIView.animate(withDuration: 0.12) { webView.alpha = 1 } }
            guard generation == loadGeneration,
                  let dimensions = result as? [Double], dimensions.count == 2,
                  let contentWidth = dimensions.first, let contentHeight = dimensions.last,
                  contentWidth > 0, contentHeight > 0 else { return nil }
            let viewportWidth = webView.bounds.width
            // Uniformly shrink the whole rendered page to fit, rather than
            // per-element CSS clamping that broke proportions (see wrap()'s
            // doc comment). Never scale a narrower-than-device email UP;
            // only shrink an oversized one.
            let scale = viewportWidth > 0 && contentWidth > viewportWidth ? viewportWidth / contentWidth : 1
            webView.scrollView.minimumZoomScale = scale
            webView.scrollView.maximumZoomScale = scale
            webView.scrollView.zoomScale = scale
            let scaledHeight = contentHeight * scale
            parent.height = scaledHeight
            return scaledHeight
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            print("HTMLMessageBody: navigation failed: \(error)")
            webView.alpha = 1 // must not stay hidden forever on a failed load
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            print("HTMLMessageBody: provisional navigation failed: \(error)")
            webView.alpha = 1
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            LinkOpener.open(url)
            decisionHandler(.cancel)
        }
    }
}
