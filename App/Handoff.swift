import Foundation

/// Handoff: the conversation open on your iPhone is a click away on your
/// Mac (and the other way), in the Dock and the app switcher.
enum Handoff {
    static let conversation = "studio.anwarcreative.corres.conversation"

    static func describe(_ activity: NSUserActivity, _ thread: Correspondence) {
        activity.title = thread.subject.isEmpty ? thread.sender : thread.subject
        activity.userInfo = ["account": thread.id.account, "thread": thread.id.providerID]
        activity.isEligibleForHandoff = thread.id.account != "sample"
        activity.isEligibleForSearch = false
    }

    static func threadID(_ activity: NSUserActivity) -> ThreadID? {
        guard let account = activity.userInfo?["account"] as? String,
              let thread = activity.userInfo?["thread"] as? String else { return nil }
        return ThreadID(account: account, providerID: thread)
    }
}
