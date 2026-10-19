import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// The few things iPhone and Mac do differently below the screens: opening
/// a link, the window a sign-in sheet hangs from, images, and how long the
/// system lets work finish in the background. Everything else in App/ is
/// the same code on both.
#if canImport(UIKit)
typealias PlatformImage = UIImage
/// What Google's sign-in sheet is presented from.
typealias SignInPresenter = UIViewController
/// A UIKit or AppKit view shown in SwiftUI.
typealias PlatformViewRepresentable = UIViewRepresentable
#else
typealias PlatformImage = NSImage
typealias SignInPresenter = NSWindow
typealias PlatformViewRepresentable = NSViewRepresentable
#endif

@MainActor
enum Platform {
    /// Opens a link in the app the system picks (Safari, Maps, Phone).
    @discardableResult
    static func open(_ url: URL) async -> Bool {
        #if canImport(UIKit)
        await UIApplication.shared.open(url)
        #else
        NSWorkspace.shared.open(url)
        #endif
    }

    /// The window in front, for a sign-in sheet to attach to.
    static var keyWindow: ASPresentationAnchorWindow? {
        #if canImport(UIKit)
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        #else
        NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow ?? NSApplication.shared.windows.first
        #endif
    }

    /// What Google's sign-in presents from: the front view controller on
    /// iPhone and iPad, the front window on the Mac.
    static var signInPresenter: SignInPresenter? {
        #if canImport(UIKit)
        var top = keyWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
        #else
        keyWindow
        #endif
    }

    /// "iOS 27.0" or "macOS 27.0", for diagnostics.
    static var systemDescription: String {
        #if canImport(UIKit)
        "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        #else
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        #endif
    }
}

#if os(macOS)
/// Images are made once and only read after, so passing one between
/// actors is safe, as UIImage already declares.
extension NSImage: @retroactive @unchecked Sendable {}
#endif

#if canImport(UIKit)
typealias ASPresentationAnchorWindow = UIWindow
#else
typealias ASPresentationAnchorWindow = NSWindow
#endif

extension PlatformImage {
    /// Decoded now, off the main thread, so scrolling never pays for it.
    func preparedForDisplay() -> PlatformImage {
        #if canImport(UIKit)
        preparingForDisplay() ?? self
        #else
        self
        #endif
    }
}

extension Image {
    init(platformImage: PlatformImage) {
        #if canImport(UIKit)
        self.init(uiImage: platformImage)
        #else
        self.init(nsImage: platformImage)
        #endif
    }
}
