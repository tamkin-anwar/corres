import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// For people using VoiceOver, Switch Control and the like: what changed,
/// said out loud, and more time for anything that goes away by itself.
@MainActor
enum Assistive {
    /// Spoken by VoiceOver without moving its cursor: "Archived. Undo
    /// available." Silent for everyone else.
    static func announce(_ text: String) {
        guard isRunning else { return }
        AccessibilityNotification.Announcement(text).post()
    }

    /// VoiceOver or Switch Control is on: reaching a button takes longer
    /// than seeing it.
    static var isRunning: Bool {
        #if canImport(UIKit)
        UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning
        #else
        NSWorkspace.shared.isVoiceOverEnabled || NSWorkspace.shared.isSwitchControlEnabled
        #endif
    }

    /// How long an Undo stays offered: a few seconds by sight, long enough
    /// to reach with VoiceOver or a switch.
    static func undoSeconds(_ usual: Int) -> Int { isRunning ? max(usual, 15) : usual }
}
