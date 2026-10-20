import AppKit
import WebKit

/// File › Print (⌘P): the open email as Mail prints it, with who it's from,
/// to whom, when and the subject above it, on white paper whatever the
/// window's appearance.
@MainActor
final class MacPrinter: NSObject, WKNavigationDelegate {
    private static var current: MacPrinter?
    private let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 800))
    private let window: NSWindow?

    static func print(_ thread: Correspondence, in window: NSWindow?) {
        let printer = MacPrinter(window: window)
        current = printer
        printer.webView.navigationDelegate = printer
        printer.webView.loadHTMLString(page(for: thread), baseURL: nil)
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
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
        Self.current = nil
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func page(for thread: Correspondence) -> String {
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
        img { max-width: 100%; height: auto; }
        </style></head><body>
        <div class="head">
        <h1 class="subject">\(escape(thread.subject.isEmpty ? "(No subject)" : thread.subject))</h1>
        <p class="row"><b>From:</b> \(from)</p>
        \(to.isEmpty ? "" : "<p class=\"row\"><b>To:</b> \(to)</p>")
        <p class="row"><b>Date:</b> \(escape(date))</p>
        </div>
        \(body)
        </body></html>
        """
    }
}
