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
    /// Read so a change of text size in Settings redraws the email.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebViewPool.shared.dequeue()
        context.coordinator.watchZoom(of: webView)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
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
        // Designed mail that ships its own dark styles gets them, as Mail
        // does; other designed mail is darkened by Corres's script when it
        // can be done safely (`sizingScript`), otherwise kept on white.
        let analysis = Self.analysis(of: html)
        let designed = analysis.isDesigned
        let dark = colorScheme == .dark
        // The person's text size (Settings → Display & Brightness → Text
        // Size), which Mail follows too. 17pt is the default.
        let textSize = UIFont.preferredFont(forTextStyle: .body, compatibleWith: webView.traitCollection).pointSize
        webView.overrideUserInterfaceStyle = designed && !analysis.hasOwnDarkMode ? .light : (dark ? .dark : .light)
        // Checked against the raw inputs, not the processed/wrapped output:
        // SwiftUI re-invokes updateUIView on any state change anywhere this
        // view observes (e.g. an unrelated background sync mutating
        // store.threads), not only when html/blockRemoteImages actually
        // changed. Guarding here first, before ever touching
        // blockingRemoteImages's regex work, means an unrelated re-render
        // costs nothing instead of re-running a full-body regex scan.
        guard context.coordinator.lastHTML != html || context.coordinator.lastBlockRemoteImages != blockRemoteImages
              || context.coordinator.lastDark != dark || context.coordinator.lastTextSize != textSize else { return }
        context.coordinator.lastHTML = html
        context.coordinator.lastBlockRemoteImages = blockRemoteImages
        context.coordinator.lastDark = dark
        context.coordinator.lastTextSize = textSize
        // Invalidates any re-measurement still scheduled from a previous
        // load on this same (possibly pooled/reused) webview instance; see
        // Coordinator.loadGeneration.
        context.coordinator.loadGeneration = Coordinator.nextLoad()
        context.coordinator.hasSize = false
        context.coordinator.resetZoom(webView)
        WKWebViewPool.shared.sizeRouter(for: webView).target = context.coordinator
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
        let kind: BodyKind = !designed ? .plain : analysis.hasOwnDarkMode ? .designedWithDarkMode : .designed
        webView.loadHTMLString(Self.wrap(processed, kind: kind, dark: dark, textSize: textSize,
                                         load: context.coordinator.loadGeneration),
                               baseURL: Self.placeholderBaseURL)
    }

    static let placeholderBaseURL = URL(string: "https://mail.corres.app/")

    nonisolated(unsafe) private static let plainTextPages: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 32
        return cache
    }()

    /// A plain-text email as a page (`PlainTextEmail`), worked out once
    /// per message rather than on every redraw.
    static func page(forPlainText text: String) -> String {
        if let cached = plainTextPages.object(forKey: text as NSString) { return cached as String }
        let page = PlainTextEmail.html(from: text)
        plainTextPages.setObject(page as NSString, forKey: text as NSString)
        return page
    }

    /// Corres's own script, in its own content world: it runs even though
    /// the email's scripts never do (`allowsContentJavaScript` is off, and
    /// that only stops the page's own JavaScript). It never changes what
    /// the email says or loads, only its scale, and reports the size.
    ///
    /// Fit: the email lays out at its own width. When that's wider than
    /// the screen (a fixed 600–700px newsletter or receipt), the whole
    /// email is scaled down to fit, keeping its design intact, as Mail and
    /// Gmail do. Narrower mail is never scaled up.
    ///
    /// Size: re-measured on every change rather than a few times after
    /// loading, so late images, web fonts and Show Images all fit.
    static let sizingScript = #"""
    (() => {
      const root = document.getElementById('corres-root');
      if (!root) return;
      const meta = document.querySelector('meta[name="corres-load"]');
      const load = meta ? Number(meta.content) : 0;
      let lastHeight = -1, lastScale = -1, pending = false;
      function measure() {
        pending = false;
        const viewport = document.documentElement.clientWidth || window.innerWidth;
        root.style.transform = '';
        root.style.width = '';
        // Content wider than the screen: its full width, plus the right
        // margin, which an overflowing box's scrollWidth leaves out.
        const overflowing = root.scrollWidth > root.clientWidth + 1;
        const natural = overflowing
          ? root.scrollWidth + (parseFloat(getComputedStyle(root).paddingRight) || 0)
          : root.offsetWidth;
        let scale = 1;
        if (viewport > 0 && natural > viewport + 1) {
          scale = viewport / natural;
          root.style.width = natural + 'px';
          root.style.transformOrigin = '0 0';
          root.style.transform = 'scale(' + scale + ')';
        }
        const height = Math.ceil(Math.max(root.getBoundingClientRect().height, root.scrollHeight * scale));
        // A scaled email's layout is taller than what shows; pin the page
        // to the shown height so zooming in never reveals blank space.
        for (const element of [document.documentElement, document.body]) {
          if (scale < 1) element.style.setProperty('height', height + 'px', 'important');
          else element.style.removeProperty('height');
        }
        if (height !== lastHeight || scale !== lastScale) {
          lastHeight = height; lastScale = scale;
          window.webkit.messageHandlers.corresSize.postMessage({ load: load, height: height, scale: scale });
        }
      }
      function schedule() {
        if (pending) return;
        pending = true;
        requestAnimationFrame(measure);
      }
      // MARK: Dark mode for designed mail
      //
      // Mail that sets its own look (white tables, grey text, a footer
      // box) was shown on a white card in Dark mode. Like Mail, its
      // colours are mapped instead: light backgrounds go dark, keeping
      // their hue (white, the page itself, goes to Corres's background),
      // and dark text inside them goes light. Anything already dark or
      // strongly coloured (a black button, a yellow banner) keeps its own
      // colours, and so does the text on it. Mail whose look depends on
      // pictures is left on white: a transparent logo drawn for a white
      // page would disappear on a dark one, and there's no way to tell
      // from here which pictures are transparent.
      function parse(value) {
        const match = /rgba?\(([^)]+)\)/.exec(value || '');
        if (!match) return null;
        const parts = match[1].split(/[\s,/]+/).filter(Boolean).map(Number);
        if (parts.length < 3 || parts.some(isNaN)) return null;
        return { r: parts[0] / 255, g: parts[1] / 255, b: parts[2] / 255, a: parts.length > 3 ? parts[3] : 1 };
      }
      function hsl(c) {
        const max = Math.max(c.r, c.g, c.b), min = Math.min(c.r, c.g, c.b), l = (max + min) / 2;
        let h = 0, s = 0;
        if (max !== min) {
          const d = max - min;
          s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
          h = max === c.r ? (c.g - c.b) / d + (c.g < c.b ? 6 : 0) : max === c.g ? (c.b - c.r) / d + 2 : (c.r - c.g) / d + 4;
          h *= 60;
        }
        return { h, s, l };
      }
      function css(h, s, l, a) {
        return 'hsla(' + h.toFixed(1) + ', ' + (s * 100).toFixed(1) + '%, ' + (l * 100).toFixed(1) + '%, ' + a + ')';
      }
      // A light background, darkened: white → 12%, light grey → a little lighter.
      function darkBackground(c) {
        const { h, s, l } = hsl(c);
        return css(h, s * 0.5, Math.min(0.42, 0.12 + (1 - l)), c.a);
      }
      // Dark text, lightened: black → 93%, mid grey → about 72%.
      function lightText(c) {
        const { h, s, l } = hsl(c);
        return css(h, s, 0.93 - l * 0.5, c.a);
      }
      const blockedPixel = 'data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP';
      function dependsOnPictures(elements) {
        for (const element of elements) {
          const tag = element.tagName;
          if (tag === 'svg' || tag === 'CANVAS' || tag === 'VIDEO') return true;
          if (tag === 'IMG') {
            const src = element.getAttribute('src') || '';
            if (src.startsWith(blockedPixel)) continue;           // not shown
            if (/\.jpe?g(\?|#|$)|^data:image\/jpe?g/i.test(src)) continue; // photos are never transparent
            const width = element.naturalWidth || Number(element.getAttribute('width')) || element.offsetWidth;
            const height = element.naturalHeight || Number(element.getAttribute('height')) || element.offsetHeight;
            if ((width && width <= 3) || (height && height <= 3)) continue; // tracking pixels
            return true;
          }
          const style = getComputedStyle(element);
          if (style.backgroundImage && style.backgroundImage !== 'none') return true;
        }
        return false;
      }
      function darken() {
        const meta = document.querySelector('meta[name="corres-dark"]');
        if (!meta || meta.content !== '1' || root.classList.contains('own-dark')) return;
        // Mail from people is already dark; only colours its sender set
        // (grey signatures, coloured quotes) need mapping, pictures or not.
        const plain = root.classList.contains('plain');
        const elements = root.getElementsByTagName('*');
        if (elements.length > 8000 || (!plain && dependsOnPictures(elements))) return;
        // Read everything first, then write, so the page is styled once.
        const changes = [];
        // An email's own <body> styles land on the real page (the parser
        // merges a second <body> into the first): a light page colour
        // there is the page itself, and goes to Corres's background too.
        for (const element of [document.documentElement, document.body]) {
          const background = parse(getComputedStyle(element).backgroundColor);
          if (background && background.a > 0.05 && hsl(background).l >= 0.7) {
            changes.push([element, 'background-color', 'transparent']);
          }
        }
        const sides = ['top', 'right', 'bottom', 'left'];
        // `onPage`: drawn straight on the page (no background of its own
        // between it and the page). `mapped`: on a background Corres darkened.
        (function visit(element, onPage, mapped) {
          const style = getComputedStyle(element);
          // Folded quotes are still coloured, for when they're opened.
          if (style.display === 'none' && !element.classList.contains('corres-folded')) return;
          const background = parse(style.backgroundColor);
          if (background && background.a > 0.05) {
            const { s, l } = hsl(background);
            if (l >= 0.7) {
              const value = onPage && l >= 0.97 && s < 0.15 ? 'transparent' : darkBackground(background);
              changes.push([element, 'background-color', value]);
              mapped = true; onPage = onPage && value === 'transparent';
            } else {
              mapped = false; onPage = false;
            }
          }
          if (mapped) {
            const color = parse(style.color);
            if (color && hsl(color).l < 0.6) changes.push([element, 'color', lightText(color)]);
            for (const side of sides) {
              if (parseFloat(style.getPropertyValue('border-' + side + '-width')) > 0) {
                const border = parse(style.getPropertyValue('border-' + side + '-color'));
                if (border && border.a > 0.05 && hsl(border).l >= 0.7) {
                  changes.push([element, 'border-' + side + '-color', darkBackground(border)]);
                }
              }
            }
          }
          for (const child of element.children) visit(child, onPage, mapped);
        })(root, true, true);
        for (const [element, property, value] of changes) element.style.setProperty(property, value, 'important');
        document.documentElement.classList.add('corres-dark');
      }

      // MARK: Margins for designed mail
      //
      // Mail from people gets Corres's page margin. Designed mail brings
      // its own, anywhere from none (text against the screen's edge) to
      // plenty, so it's measured: its text is moved in until it sits at
      // least the page margin from the edge, and never further. A design
      // wider than the screen, about to be shrunk to fit, gets a small
      // margin so it doesn't touch the edges.
      function fitMargins() {
        if (!root.classList.contains('designed')) return;
        const page = 20;
        if (root.scrollWidth > root.clientWidth + 1) {
          root.style.padding = '0 8px';
          return;
        }
        const width = root.clientWidth;
        let inset = page;
        const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
        const range = document.createRange();
        for (let count = 0, node; (node = walker.nextNode()) && count < 400;) {
          if (!node.data.trim()) continue;
          count++;
          range.selectNodeContents(node);
          for (const rect of range.getClientRects()) {
            if (rect.width < 1 || rect.height < 1) continue;
            inset = Math.min(inset, rect.left, width - rect.right);
          }
          if (inset <= 0) break;
        }
        const padding = Math.max(0, Math.ceil(page - Math.max(0, inset)));
        if (padding > 0) root.style.padding = '0 ' + padding + 'px';
        // The person's text size, for a design that reflows (one that's
        // shrunk to fit keeps its own sizes, as Mail does). Mail set in
        // desktop sizes (Outlook's 11pt Calibri is about 15px) is brought
        // up to a size that reads on a phone, the way Mail and Gmail do.
        const scaleMeta = document.querySelector('meta[name="corres-text-scale"]');
        let textScale = scaleMeta ? Number(scaleMeta.content) || 1 : 1;
        const body = typicalTextSize();
        if (body > 0 && body < 15.5) textScale *= Math.min(17 / body, 1.3);
        if (Math.abs(textScale - 1) > 0.01) {
          root.style.setProperty('-webkit-text-size-adjust', Math.round(textScale * 100) + '%');
        }
      }

      // The size most of the email's text is set in, by amount of text.
      function typicalTextSize() {
        const amounts = new Map();
        const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
        for (let count = 0, node; (node = walker.nextNode()) && count < 400;) {
          const length = node.data.trim().length;
          if (!length || !node.parentElement || !node.parentElement.offsetHeight) continue;
          count++;
          const size = parseFloat(getComputedStyle(node.parentElement).fontSize);
          amounts.set(size, (amounts.get(size) || 0) + length);
        }
        let best = 0, most = 0;
        amounts.forEach((amount, size) => { if (amount > most) { most = amount; best = size; } });
        return best;
      }

      // MARK: Wide tables in mail from people
      //
      // A pasted spreadsheet or a wide signature table made the sizing
      // script shrink the whole message, text and all. In mail from people
      // the table scrolls sideways on its own instead.
      function containWideTables() {
        if (!root.classList.contains('plain')) return;
        const limit = root.clientWidth - 40;
        for (const table of Array.from(root.querySelectorAll('table'))) {
          if (table.parentElement.closest('table') || table.offsetWidth <= limit + 1) continue;
          const box = document.createElement('div');
          box.className = 'corres-scroll';
          table.parentNode.insertBefore(box, table);
          box.appendChild(table);
        }
      }

      // MARK: Quoted history
      //
      // Each reply carries the whole conversation below it, which Corres
      // already shows above the message. Like Gmail and Mail, it's folded
      // behind a ••• button. Only history at the end is folded: an
      // interleaved reply (answers between quoted lines) and a forward
      // (the point of the email) are left open, and so is a message that
      // is nothing but a quote.
      // Containers hold the whole quote; headers start it, and everything
      // after them is the history (Outlook's "From: … Sent: …" block).
      const quoteContainers = ['.gmail_quote', '.corres-quote', 'blockquote[type="cite"]', '.yahoo_quoted',
        '.protonmail_quote', '#mail-editor-reference-message-container'];
      const quoteHeaders = ['#divRplyFwdMsg', '#appendonsend', '.moz-cite-prefix', '#x_divRplyFwdMsg',
        'div[style*="border-top:solid #E1E1E1"]', 'div[style*="border-top: solid #E1E1E1"]',
        'div[style*="border-top:solid #B5C4DF"]', 'div[style*="border-top: solid #B5C4DF"]'];
      function text(range) { return range.toString().replace(/\s+/g, ' ').trim(); }
      function textBefore(node) {
        const range = document.createRange();
        range.setStart(root, 0); range.setEndBefore(node);
        return text(range);
      }
      function textAfter(node) {
        const range = document.createRange();
        range.setStartAfter(node); range.setEnd(root, root.childNodes.length);
        return text(range);
      }
      function isForward(node) {
        const start = (node.innerText || node.textContent || '').slice(0, 600);
        return /forwarded message|begin forwarded|weitergeleitete nachricht|message transféré|subject:\s*(fw|fwd)\b/i.test(start);
      }
      function findQuote() {
        const header = root.querySelector(quoteHeaders.join(','));
        const container = Array.from(root.querySelectorAll(quoteContainers.join(',')))
          .find(node => !node.parentElement.closest(quoteContainers.join(',')) && !textAfter(node));
        // Whichever comes first in the email.
        let found = header;
        if (container && (!header || (header.compareDocumentPosition(container) & Node.DOCUMENT_POSITION_PRECEDING))) found = container;
        if (!found || isForward(found)) return null;
        const before = textBefore(found);
        if (before.length < 1 || /(forwarded message|begin forwarded)[^]{0,80}$/i.test(before)) return null;
        return found;
      }
      function foldQuote() {
        const start = findQuote();
        if (!start) return;
        // The quote and everything after it, at every level up to the email.
        const hidden = [];
        const previous = start.previousElementSibling;
        if (previous && previous.tagName === 'HR') hidden.push(previous);
        for (let node = start; node && node !== root; node = node.parentNode) {
          for (let sibling = node === start ? node : node.nextSibling; sibling; sibling = sibling.nextSibling) {
            if (sibling.nodeType === Node.TEXT_NODE) {
              if (!sibling.data.trim()) continue;
              const span = document.createElement('span');
              sibling.parentNode.insertBefore(span, sibling);
              span.appendChild(sibling);
              sibling = span;
            }
            if (sibling.nodeType === Node.ELEMENT_NODE) hidden.push(sibling);
          }
        }
        // Blank lines and empty paragraphs left just above the quote.
        for (let node = hidden[0].previousSibling; node; node = node.previousSibling) {
          if (node.nodeType === Node.TEXT_NODE && !node.data.trim()) continue;
          if (node.nodeType === Node.ELEMENT_NODE && /^(BR|DIV|P)$/.test(node.tagName) && !node.textContent.trim()
              && !node.querySelector('img')) { hidden.unshift(node); continue; }
          break;
        }
        hidden.forEach(node => node.classList.add('corres-folded'));
        const fold = document.createElement('div');
        fold.className = 'corres-fold';
        // A link, not a button: with the email's own scripts off, WebKit
        // doesn't deliver taps to page elements, only link navigation,
        // which Corres catches (`Coordinator.foldPath`) and answers by
        // calling `corresToggleQuote`.
        const button = document.createElement('a');
        button.href = 'https://mail.corres.app/fold';
        button.textContent = '•••';
        button.setAttribute('role', 'button');
        button.setAttribute('aria-label', 'Show quoted text');
        button.setAttribute('aria-expanded', 'false');
        window.corresToggleQuote = () => {
          const open = button.getAttribute('aria-expanded') !== 'true';
          hidden.forEach(node => node.classList.toggle('corres-folded', !open));
          button.setAttribute('aria-expanded', String(open));
          button.setAttribute('aria-label', open ? 'Hide quoted text' : 'Show quoted text');
        };
        fold.appendChild(button);
        hidden[0].parentNode.insertBefore(fold, hidden[0]);
      }

      // Flight and tracking numbers iOS finds ("misc") do nothing when
      // tapped in a view like this, unlike addresses and phone numbers.
      // Turned into ordinary links carrying their text, so a tap reaches
      // Corres (`Coordinator.detectedItemPath`).
      function adoptMisc(link) {
        if (link.getAttribute('x-apple-data-detectors-type') !== 'misc') return;
        const text = link.innerText.trim();
        link.removeAttribute('x-apple-data-detectors');
        link.setAttribute('href', 'https://mail.corres.app/detected?text=' + encodeURIComponent(text));
      }
      function adoptAll() { root.querySelectorAll('a[x-apple-data-detectors-type="misc"]').forEach(adoptMisc); }
      new MutationObserver(adoptAll).observe(root, { childList: true, subtree: true });
      adoptAll();
      foldQuote();
      containWideTables();
      darken();
      fitMargins();
      window.corresMeasure = measure;
      new ResizeObserver(schedule).observe(root);
      document.addEventListener('load', schedule, true);
      document.addEventListener('error', schedule, true);
      window.addEventListener('resize', schedule);
      if (document.fonts) document.fonts.ready.then(schedule);
      measure();
    })();
    """#

    /// How many `<img>` tags in `html` point at a remote http(s) URL, so a
    /// caller can show a "N images blocked" banner without needing its own
    /// WKWebView instance to find out.
    /// What the reading view needs to know about a message's HTML, worked
    /// out once per message: each of these scans the whole body, and the
    /// view asks on every redraw (the web view reporting its height, a
    /// summary arriving, a sync landing), which is what made opening a
    /// long designed email stutter.
    struct Analysis {
        let isDesigned: Bool
        let hasOwnDarkMode: Bool
        let remoteImages: Int
        let trackers: Int
    }

    private final class AnalysisBox {
        let value: Analysis
        init(_ value: Analysis) { self.value = value }
    }

    nonisolated(unsafe) private static let analysisCache: NSCache<NSString, AnalysisBox> = {
        let cache = NSCache<NSString, AnalysisBox>()
        cache.countLimit = 64
        return cache
    }()

    static func analysis(of html: String) -> Analysis {
        let key = html as NSString
        if let cached = analysisCache.object(forKey: key) { return cached.value }
        let remote = remoteImageCount(in: html)
        let value = Analysis(isDesigned: isDesigned(html), hasOwnDarkMode: hasOwnDarkMode(html), remoteImages: remote,
                             trackers: remote > 0 ? trackerCount(in: html) : 0)
        analysisCache.setObject(AnalysisBox(value), forKey: key)
        return value
    }

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
    /// sender's content) and interfere with the fit Corres manages
    /// itself (`sizingScript`). Stripped unconditionally so
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
    /// math divided the whole page, text
    /// included, down to a small fraction of size for content that never
    /// needed to shrink at all.
    ///
    /// This still correctly handles real wide marketing HTML (fixed-width
    /// tables/images sized in raw pixels, not percentages): those don't
    /// shrink to fit `device-width` just because the viewport meta says
    /// so, they overflow it outright, and `scrollWidth` reports that real
    /// overflow (the full extent including anything sticking out past the
    /// viewport, not just the viewport's own width) regardless of which
    /// width the viewport meta requested. `sizingScript` only shrinks when
    /// there's real overflow to correct; the earlier bug was that
    /// forcing `width=1024` manufactured false overflow for content that
    /// never had any, not a flaw in that check itself.
    ///
    /// Mail that sets its own look: background colours, colour on its
    /// text, or a style sheet (marketing, receipts, notifications, and
    /// mail from Outlook). Plain mail from Gmail or Mail has none of these.
    static func isDesigned(_ html: String) -> Bool {
        html.range(of: #"bgcolor\s*=|background(-color)?\s*:\s*(#|rgb|white)|<style[\s>]"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Designed mail with its own Dark mode styles: a
    /// `prefers-color-scheme: dark` rule, or a `color-scheme` that
    /// includes dark.
    static func hasOwnDarkMode(_ html: String) -> Bool {
        html.range(of: #"prefers-color-scheme\s*:\s*dark|color-schemes?["']?\s*(content\s*=\s*["']|:)[^"';>]*dark"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    enum BodyKind { case plain, designed, designedWithDarkMode }

    /// Built directly for each kind of mail, never by editing the finished
    /// page: an earlier version removed the dark-mode rules from designed
    /// mail with a pattern that, when it missed its own rules, ran on into
    /// the email itself and deleted everything up to some later match,
    /// taking the start of the email (and the wrapper the sizing script
    /// needs) with it.
    ///
    /// Mail from people adapts to Dark mode. The dark rules use `!important`
    /// deliberately: real mail HTML (Gmail's own quoted-reply markup
    /// included) sets its own inline `color` on elements, and an
    /// `!important` author rule is the one thing that outranks it. Literal
    /// colours rather than `-apple-system-label`, which didn't reliably
    /// follow `overrideUserInterfaceStyle` in a `loadHTMLString` page on a
    /// real device. Designed mail is shown as its sender made it: light
    /// only, on white, in their colours.
    private static func wrap(_ html: String, kind: BodyKind, dark: Bool, textSize: CGFloat, load: Int = 0) -> String {
        let adaptiveRules = """
            :root { color-scheme: light dark; }
            @media (prefers-color-scheme: dark) { body { color: #F2F3F5 !important; } a { color: #8FB4E8; } }
            """
        let styles: String
        switch kind {
        case .plain, .designedWithDarkMode:
            styles = adaptiveRules
        case .designed:
            // White until the script darkens it (`corres-dark`).
            styles = """
                :root { color-scheme: light only; }
                html:not(.corres-dark), html:not(.corres-dark) body { background: #FFFFFF !important; }
                html.corres-dark a[x-apple-data-detectors], html.corres-dark a[href^="https://mail.corres.app/detected"] {
                  color: inherit !important; }
                """
        }
        return wrapAdaptive(html, load: load, dark: dark, textSize: textSize, styles: styles,
                            rootClass: kind == .plain ? "plain" : kind == .designed ? "designed" : "designed own-dark")
    }

    private static func wrapAdaptive(_ html: String, load: Int, dark: Bool, textSize: CGFloat, styles: String,
                                     rootClass: String) -> String {
        let size = max(12, min(textSize, 40))
        return """
        <html><head><meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="corres-load" content="\(load)">
        <meta name="corres-dark" content="\(dark ? 1 : 0)">
        <meta name="corres-text-scale" content="\(String(format: "%.3f", size / 17))">
        <style>
        body { font: -apple-system-body; font-size: \(String(format: "%.1f", size))px; line-height: 1.5; color: #141312 !important;
               margin: 0; padding: 0; -webkit-text-size-adjust: 100%;
               background: transparent; }
        a { color: #2F5D9E; }
        /* The email lays out as its sender built it; nothing here narrows
           its tables or cells. A design wider than the screen (most
           marketing mail and receipts are fixed 600–700px tables) is
           shrunk as a whole to fit by the sizing script (`sizingScript`),
           the way Mail and Gmail show it. Forcing tables and cells to the
           screen's width instead squeezed fixed-width columns into broken
           layouts, and clipping overflow hid their right edges. */
        /* Long unbroken text in mail from people (a pasted link, a code
           snippet) wraps instead of widening the whole message. */
        #corres-root { display: flow-root; overflow-wrap: break-word; box-sizing: border-box; }
        /* Mail from people lines up with the rest of the conversation
           (CorresSpace.page). Designed mail gets margins from the sizing
           script, measured against the email's own (`sizingScript`). */
        #corres-root.plain { padding: 0 20px; }
        /* Designed mail keeps the line spacing it was designed with. */
        #corres-root.designed { line-height: normal; }
        /* Quoted mail in mail from people, as Mail draws it. */
        #corres-root.plain .gmail_quote, #corres-root.plain .corres-quote { color: rgba(128, 128, 128, 1); }
        #corres-root.plain blockquote[type="cite"] { margin: 8px 0; padding: 0 0 0 12px;
          border-left: 2px solid rgba(128, 128, 128, 0.45); color: rgba(128, 128, 128, 1) !important; }
        .corres-plain-text { font: inherit; }
        /* A wide table in mail from people scrolls sideways on its own
           rather than shrinking the whole message (`sizingScript`). */
        .corres-scroll { overflow-x: auto; max-width: 100%; }
        /* Quoted history, folded behind a button (`sizingScript`). */
        .corres-folded { display: none !important; }
        .corres-fold { margin: 14px 0 10px; line-height: 1; text-align: left; }
        .corres-fold a { display: inline-block; border-radius: 11px; text-decoration: none !important;
          padding: 2px 14px 9px; font: 600 20px/1 -apple-system; letter-spacing: 2px;
          color: rgba(128, 128, 128, 1) !important; background: rgba(128, 128, 128, 0.16) !important; }
        .corres-fold a[aria-expanded="true"] { background: rgba(128, 128, 128, 0.28) !important; }
        pre { white-space: pre-wrap; }
        img { max-width: 100%; height: auto; }
        /* Measured, not viewport-sized: emails that make their wrapper
           "full screen" (height: 100%, min-height: 100vh) grew every time
           the view grew to fit them, leaving an endless blank tail below
           the message. Their height comes from their content instead. */
        html, body { height: auto !important; min-height: 0 !important; }
        [height="100%"], [style*="height:100%"], [style*="height: 100%"], [style*="vh"] {
          height: auto !important; min-height: 0 !important; }
        \(styles)
        </style></head><body><div id="corres-root" class="\(rootClass)">\(html)</div></body></html>
        """
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: HTMLMessageBody
        var lastHTML: String?
        var lastBlockRemoteImages: Bool?
        var lastDark: Bool?
        var lastTextSize: CGFloat?
        init(_ parent: HTMLMessageBody) { self.parent = parent }

        /// A generation counter, bumped every time a fresh load starts
        /// (`updateUIView`), so a re-measurement scheduled for an earlier
        /// load can recognize it's stale (the webview has since been reused
        /// for a different conversation, borrowed back from the pool) and
        /// bail out instead of stomping a newer conversation's correct size
        /// with a late measurement of the previous one's.
        var loadGeneration = 0

        static let detectedItemPath = "/detected"
        static let foldPath = "/fold"

        /// Load numbers unique across every message, not per view: a
        /// reused webview can still deliver a late report from the previous
        /// message's page, and a per-view count would let it pass as this
        /// one's.
        private static var lastLoad = 0
        static func nextLoad() -> Int {
            lastLoad += 1
            return lastLoad
        }

        /// Whether this load has reported its size yet.
        var hasSize = false
        /// The email's fitted height at normal size; zoomed, the view is
        /// this times the zoom.
        private var baseHeight: CGFloat = 0
        private var contentSizeObservation: NSKeyValueObservation?
        private var settleZoom: Task<Void, Never>?

        // MARK: Pinch to zoom
        //
        // WebKit zooms the email natively (pinch, or double-tap). While the
        // fingers are down the view keeps its size and the email zooms
        // inside it; once it settles, the view grows (or shrinks) to the
        // zoomed height so the whole email still scrolls with the
        // conversation, and the part that was under the fingers is kept in
        // place by moving the conversation by the same amount. Zoomed in,
        // the email pans sideways within itself; up and down always scrolls
        // the conversation. Each email opens at normal size.

        func watchZoom(of webView: WKWebView) {
            contentSizeObservation = webView.scrollView.observe(\.contentSize, options: [.new]) { [weak self, weak webView] _, _ in
                MainActor.assumeIsolated {
                    guard let self, let webView else { return }
                    self.zoomChanged(webView)
                }
            }
        }

        func resetZoom(_ webView: WKWebView) {
            settleZoom?.cancel()
            webView.scrollView.setZoomScale(1, animated: false)
            webView.scrollView.isScrollEnabled = false
            webView.scrollView.contentOffset = .zero
        }

        private func zoomChanged(_ webView: WKWebView) {
            settleZoom?.cancel()
            settleZoom = Task { @MainActor [weak self, weak webView] in
                // After the pinch (and any bounce) has finished.
                try? await Task.sleep(for: .milliseconds(120))
                guard let self, let webView, !Task.isCancelled else { return }
                let pinch = webView.scrollView.pinchGestureRecognizer?.state
                guard pinch != .began && pinch != .changed else { return }
                self.applyZoom(webView)
            }
        }

        private func applyZoom(_ webView: WKWebView) {
            let scrollView = webView.scrollView
            let zoom = scrollView.zoomScale
            guard baseHeight > 0 else { return }
            let isZoomed = zoom > 1.01
            scrollView.isScrollEnabled = isZoomed
            let target = (baseHeight * zoom).rounded()
            // The vertical part of WebKit's zoom anchor moves to the
            // conversation, so what was under the fingers stays put.
            let verticalOffset = scrollView.contentOffset.y
            if abs(parent.height - target) >= 1 { parent.height = target }
            if verticalOffset != 0 {
                scrollView.contentOffset.y = 0
                if let outer = Self.enclosingScrollView(of: webView) {
                    outer.contentOffset.y = max(-outer.adjustedContentInset.top, outer.contentOffset.y + verticalOffset)
                }
            }
            if !isZoomed { scrollView.contentOffset.x = 0 }
        }

        private static func enclosingScrollView(of view: UIView) -> UIScrollView? {
            var current = view.superview
            while let candidate = current {
                if let scroll = candidate as? UIScrollView { return scroll }
                current = candidate.superview
            }
            return nil
        }

        /// The sizing script (`HTMLMessageBody.sizingScript`) reports the
        /// email's height whenever it changes: on layout, as each image
        /// loads (however late), when web fonts arrive, and when the width
        /// changes. Measuring a fixed number of times after the page
        /// finished, as this used to, froze the height before slow images
        /// arrived, and since the email doesn't scroll on its own (it
        /// scrolls with the conversation), everything below was cut off.
        func receiveSize(load: Int, height: CGFloat, webView: WKWebView?) {
            guard load == loadGeneration, height > 0 else { return }
            if !hasSize {
                hasSize = true
                if let webView, webView.alpha < 1 { UIView.animate(withDuration: 0.12) { webView.alpha = 1 } }
            }
            baseHeight = height
            let zoomed = height * (webView?.scrollView.zoomScale ?? 1)
            if abs(parent.height - zoomed) >= 1 { parent.height = zoomed }

        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let generation = loadGeneration
            // A backstop in case the script's first report hasn't arrived:
            // ask it to measure now, and never leave the email hidden.
            Task { @MainActor [weak self, weak webView] in
                try? await Task.sleep(for: .milliseconds(300))
                guard let self, let webView, generation == self.loadGeneration, !self.hasSize else { return }
                _ = try? await webView.evaluateJavaScript("window.corresMeasure && window.corresMeasure()",
                                                          in: nil, contentWorld: .defaultClient)
                try? await Task.sleep(for: .milliseconds(300))
                guard generation == self.loadGeneration else { return }
                if webView.alpha < 1 { UIView.animate(withDuration: 0.12) { webView.alpha = 1 } }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            print("HTMLMessageBody: navigation failed: \(error)")
            webView.alpha = 1 // must not stay hidden forever on a failed load
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            print("HTMLMessageBody: provisional navigation failed: \(error)")
            webView.alpha = 1
        }

        /// Only the email itself ever loads in the reading view. Every
        /// other navigation, whatever started it (a tap, a long-press's
        /// Open Link, a redirect), opens outside it: a website never
        /// replaces the email.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            // Async, not the completion-handler form: that form's signature
            // drifted from the SDK's, so it only "nearly matched" and iOS
            // never called it. No link tap was ever handled.
            guard let url = navigationAction.request.url else { return .cancel }
            // The email being loaded (and a reused webview being cleared).
            if navigationAction.navigationType == .other,
               url.absoluteString == "about:blank" || url == HTMLMessageBody.placeholderBaseURL {
                return .allow
            }
            // An address, phone number or date iOS found in the text. WebKit
            // marks them but doesn't act on a tap in a view like this, so
            // Corres does, as Mail does: Maps, Phone, Calendar.
            if url.scheme == "x-apple-data-detectors" {
                await openDetected(url, in: webView)
                return .cancel
            }
            // The ••• that shows or hides quoted history (see `sizingScript`).
            if url.host == HTMLMessageBody.placeholderBaseURL?.host, url.path == Self.foldPath {
                _ = try? await webView.evaluateJavaScript("window.corresToggleQuote && window.corresToggleQuote()",
                                                          in: nil, contentWorld: .defaultClient)
                return .cancel
            }
            // A flight or tracking number (see `sizingScript`).
            if url.host == HTMLMessageBody.placeholderBaseURL?.host, url.path == Self.detectedItemPath,
               let text = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "text" })?.value {
                if let target = DetectedItems.destination(forMisc: text) { LinkOpener.open(target) }
                return .cancel
            }
            // An embedded frame loading itself, or a jump within the email
            // ("#top"): nothing to open.
            let isSubframeLoad = navigationAction.targetFrame.map { !$0.isMainFrame } ?? false
            if isSubframeLoad && navigationAction.navigationType == .other { return .cancel }
            // A jump within the email (a newsletter's contents, "Back to
            // top"): the email doesn't scroll on its own, so the
            // conversation scrolls to the spot.
            if url.host == HTMLMessageBody.placeholderBaseURL?.host, let fragment = url.fragment {
                await scroll(to: fragment, in: webView)
                return .cancel
            }
            LinkOpener.open(url)
            return .cancel
        }

        private func scroll(to fragment: String, in webView: WKWebView) async {
            let script = """
            (() => { const name = decodeURIComponent(\(Self.jsString(fragment)));
              const target = name === 'top' ? document.body : (document.getElementById(name) || document.getElementsByName(name)[0]);
              return target ? target.getBoundingClientRect().top + window.scrollY : null; })()
            """
            guard let top = try? await webView.evaluateJavaScript(script, in: nil, contentWorld: .defaultClient) as? Double,
                  let outer = Self.enclosingScrollView(of: webView) else { return }
            let point = webView.convert(CGPoint(x: 0, y: top * webView.scrollView.zoomScale), to: outer)
            let inset = outer.adjustedContentInset
            let highest = max(-inset.top, outer.contentSize.height - outer.bounds.height + inset.bottom)
            let y = min(max(point.y - inset.top - 12, -inset.top), highest)
            outer.setContentOffset(CGPoint(x: outer.contentOffset.x, y: y), animated: true)
        }

        private func openDetected(_ url: URL, in webView: WKWebView) async {
            let script = """
            (() => { const a = Array.from(document.querySelectorAll('a[x-apple-data-detectors]'))
                .find(link => link.href === \(Self.jsString(url.absoluteString)));
              return a ? [a.getAttribute('x-apple-data-detectors-type') || '', a.innerText] : null; })()
            """
            guard let found = try? await webView.evaluateJavaScript(script, in: nil, contentWorld: .defaultClient) as? [String],
                  found.count == 2 else { return }
            let text = found[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if let target = Self.destination(forDetected: found[0], text: text) { LinkOpener.open(target) }
        }

        /// Where a detected item goes: an address to Maps, a phone number
        /// to a call, a date to that day in Calendar, a flight to its
        /// status, a parcel to its carrier's tracking page.
        static func destination(forDetected type: String, text: String) -> URL? {
            switch type {
            case "address":
                var components = URLComponents(string: "https://maps.apple.com/")
                components?.queryItems = [URLQueryItem(name: "q", value: text)]
                return components?.url
            case "telephone":
                let digits = text.filter { $0.isNumber || $0 == "+" }
                return digits.isEmpty ? nil : URL(string: "tel:\(digits)")
            case "calendar-event":
                let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
                guard let date = detector?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))?.date else { return nil }
                return URL(string: "calshow:\(Int(date.timeIntervalSinceReferenceDate))")
            // Flight and tracking numbers come through as "misc" (and as
            // their own types on some versions of iOS).
            case "misc", "flight-information", "flight-number", "tracking-number", "parcel-tracking":
                return DetectedItems.destination(forMisc: text)
            default:
                return nil
            }
        }

        private static func jsString(_ value: String) -> String {
            let data = try? JSONSerialization.data(withJSONObject: [value])
            let array = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
            return String(array.dropFirst().dropLast())
        }

        /// Links that ask for a new window (`target="_blank"`, used by
        /// nearly every newsletter and receipt). Without this they did
        /// nothing at all when tapped.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url { LinkOpener.open(url) }
            return nil
        }
    }
}
