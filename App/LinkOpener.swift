#if canImport(UIKit)
import SafariServices
import UIKit
#else
import AppKit
#endif

/// Where a tapped link in an email goes. Web links open in Corres (a
/// Safari view with your Safari settings, Reader and content blockers) or
/// in the default browser, per Settings → Reading. Email addresses start a
/// new message in Corres; phone numbers and other apps open as usual. On
/// the Mac, web links open in the default browser, as in Mail.
@MainActor
enum LinkOpener {
    static func open(_ url: URL) {
        switch url.scheme?.lowercased() {
        case "http", "https":
            #if canImport(UIKit)
            // Maps links open the Maps app, never a web page.
            if url.host?.lowercased() == "maps.apple.com" {
                UIApplication.shared.open(url)
                return
            }
            if CorresSettings.openLinks == .inCorres, let presenter = Platform.signInPresenter {
                let safari = SFSafariViewController(url: url)
                safari.dismissButtonStyle = .close
                presenter.present(safari, animated: true)
            } else {
                UIApplication.shared.open(url)
            }
            #else
            NSWorkspace.shared.open(url)
            #endif
        case "mailto":
            AppRouter.shared.pending = AppRouter.compose(mailto: url)
        case "tel", "sms", "facetime", "facetime-audio", "maps", "calshow":
            Task { await Platform.open(url) }
        default:
            break
        }
    }
}
