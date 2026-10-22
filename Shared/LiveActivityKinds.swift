#if os(iOS)
import ActivityKit
import Foundation

/// An email waiting in Send Later, on the Lock Screen and in the Dynamic
/// Island for its last few hours: who it's to, and when it goes. Only a
/// first name, never the subject or words, since the Lock Screen is
/// public. Compiled into the app and the widget extension.
struct SendLaterActivity: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var sendAt: Date
    }

    /// The Send Later item's id.
    var itemID: String
    /// "Maya", or "3 people".
    var recipient: String
    /// What a tap opens.
    var link: URL
}

/// A package Corres saw is out for delivery today, until the email saying
/// it arrived (or the day ends). The store and carrier only.
struct DeliveryActivity: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var delivered: Bool
    }

    /// "account|thread" of the email it came from.
    var threadKey: String
    /// "Atelier Supply".
    var from: String
    /// "UPS", when the email says.
    var carrier: String?
    var link: URL
}
#endif
