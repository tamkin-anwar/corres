import AppKit
import WebKit

/// File › Print (⌘P): the open email as Mail prints it, with who it's from,
/// to whom, when and the subject above it, on white paper whatever the
/// window's appearance.
@MainActor
final class MacPrinter: NSObject, WKNavigationDelegate {
    private static var current: MacPrinter?
    private let webView: WKWebView = {
        // Mail never runs its own scripts, printed or not.
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        return WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 800), configuration: configuration)
    }()
    private let window: NSWindow?
    /// Conversations whose images were shown with Show Images in the
    /// reading pane, so paper matches the screen, as in Mail.
    static var imagesShown: Set<ThreadID> = []

    static func print(_ thread: Correspondence, in window: NSWindow?) {
        let printer = MacPrinter(window: window)
        current = printer
        printer.webView.navigationDelegate = printer
        let allowed = thread.imagesTrusted || CorresSettings.remoteImages == .always || imagesShown.contains(thread.id)
        let hidden = allowed ? 0 : thread.htmlBody.map { HTMLMessageBody.analysis(of: $0).remoteImages } ?? 0
        let page = page(for: thread, imagesHidden: hidden > 0)
        // Prints what's on screen: images held back there stay held back on
        // paper, so printing never fetches the tracking pixels reading blocked.
        guard !allowed else {
            printer.webView.loadHTMLString(page, baseURL: nil)
            return
        }
        Task { @MainActor in
            if let list = await RemoteContentBlocker.list() {
                printer.webView.configuration.userContentController.add(list)
            }
            printer.webView.loadHTMLString(page, baseURL: nil)
        }
    }

    private init(window: NSWindow?) {
        self.window = window
        super.init()
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { run() }
    }

    private func run() {
        let info = NSPrintInfo.shared
        info.topMargin = 36; info.bottomMargin = 36; info.leftMargin = 36; info.rightMargin = 36
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        let operation = webView.printOperation(with: info)
        operation.view?.frame = webView.bounds
        if let window {
            // A sheet: it returns at once, so the page is kept until the
            // print panel is done with it, not let go while it's still up.
            operation.runModal(for: window, delegate: self, didRun: #selector(printDidRun(_:success:contextInfo:)), contextInfo: nil)
        } else {
            operation.run()
            Self.current = nil
        }
    }

    @objc private func printDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        if Self.current === self { Self.current = nil }
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func page(for thread: Correspondence, imagesHidden: Bool) -> String {
        let from = thread.senderEmail.map { "\(escape(thread.sender)) &lt;\(escape($0))&gt;" } ?? escape(thread.sender)
        let to = (thread.toRecipients + thread.ccRecipients).map(escape).joined(separator: ", ")
        let date = thread.receivedAt.formatted(date: .complete, time: .shortened)
        let body = thread.htmlBody ?? "<pre style=\"white-space:pre-wrap;font:inherit\">\(escape(thread.body))</pre>"
        return """
        <!doctype html><html><head><meta charset="utf-8"><style>
        :root { color-scheme: light; }
        body { font: 12pt -apple-system, sans-serif; color: #111; background: #fff; margin: 0; }
        .head { border-bottom: 1px solid #ccc; padding-bottom: 10px; margin-bottom: 16px; }
        .subject { font: 18pt ui-serif, "New York", Georgia, serif; margin: 0 0 8px; }
        .row { font-size: 10pt; color: #444; margin: 2px 0; }
        .row b { color: #111; font-weight: 600; }
        .note { font-size: 9pt; color: #666; margin: 8px 0 0; }
        img { max-width: 100%; height: auto; }
        </style></head><body>
        <div class="head">
        <h1 class="subject">\(escape(thread.subject.isEmpty ? String(localized: "No subject") : thread.subject))</h1>
        <p class="row"><b>From:</b> \(from)</p>
        \(to.isEmpty ? "" : "<p class=\"row\"><b>To:</b> \(to)</p>")
        <p class="row"><b>Date:</b> \(escape(date))</p>
        \(imagesHidden ? "<p class=\"note\">\(escape(String(localized: "Images hidden to protect your privacy")))</p>" : "")
        </div>
        \(body)
        </body></html>
        """
    }
}
