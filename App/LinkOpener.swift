import SafariServices
import UIKit

/// Where a tapped link in an email goes. Web links open in Corres (a
/// Safari view with your Safari settings, Reader and content blockers) or
/// in the default browser, per Settings → Reading. Email addresses start a
/// new message in Corres; phone numbers and other apps open as usual.
@MainActor
enum LinkOpener {
    static func open(_ url: URL) {
        switch url.scheme?.lowercased() {
        case "http", "https":
            // Maps links open the Maps app, never a web page.
            if url.host?.lowercased() == "maps.apple.com" {
                UIApplication.shared.open(url)
                return
            }
            if CorresSettings.openLinks == .inCorres, let presenter = topViewController() {
                let safari = SFSafariViewController(url: url)
                safari.dismissButtonStyle = .close
                presenter.present(safari, animated: true)
            } else {
                UIApplication.shared.open(url)
            }
        case "mailto":
            AppRouter.shared.pending = AppRouter.compose(mailto: url)
        case "tel", "sms", "facetime", "facetime-audio", "maps", "calshow":
            UIApplication.shared.open(url)
        default:
            break
        }
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
