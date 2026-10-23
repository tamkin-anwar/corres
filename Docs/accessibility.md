# Accessibility Nutrition Labels

What Corres can say on its App Store page under Accessibility, by device, and why. Apple's rule for every label is the same: people must be able to do all of the app's common tasks with that feature alone. A label is claimed only once that's been checked.

## Common tasks

1. Open Corres and read what's in Needs You.
2. Switch between Needs You, Primary and the other tabs, and turn on Unread Only.
3. Open an email, read it, and move to the next one.
4. Reply, and send it.
5. Archive, move to Trash, snooze and flag an email, and undo it.
6. Write a new email to someone.
7. Search for an email.
8. Open Settings and connect an email account.

## Claims

| Label | iPhone | iPad | Mac | Why |
|---|---|---|---|---|
| Larger Text | Yes | Yes | n/a (Apple doesn't offer it on Mac) | On iPhone and iPad all text follows the system text size up to the largest accessibility size. At those sizes, field names move above their fields and rows wrap instead of cutting words off. Checked with Apple's accessibility audit at AX5. The Mac meets the same bar anyway: View › Bigger and Smaller (⌘+ and ⌘−) take the sidebar, the list, the conversation, the email itself and Compose up to 200%, since macOS has no Text Size setting apps other than Apple's can read. Rows get taller and columns wider as the text grows. Settings and the toolbar keep the system's sizes. |
| Dark Interface | Yes | Yes | Yes | Follows Dark Mode everywhere, including the emails themselves. |
| Sufficient Contrast | Yes | Yes | Yes | All text colors measure at least 4.84:1 against the background in light and dark, and higher with Increase Contrast. Apple's bar is 4.5:1. |
| Differentiate Without Color Alone | Yes | Yes | Yes | Unread, flagged, pinned and VIP each have a shape or a word as well as a color. On the Mac, with the setting on, the account is named instead of only shown as a colored dot. |
| Reduced Motion | Yes | Yes | Yes | With Reduce Motion on, slides and scaling become fades. Nothing spins, zooms or plays by itself. |
| VoiceOver | After checking | After checking | After checking | Built for it (see below). Apple asks for hands-on testing of the common tasks with VoiceOver on each device before claiming it. |
| Voice Control | After checking | After checking | After checking | Built for it (see below). Same hands-on check with Voice Control. |
| Captions | n/a | n/a | n/a | Corres has no video or audio of its own. |
| Audio Descriptions | n/a | n/a | n/a | Same. |

## In App Store Connect

Entered 2026-10-22 as drafts: iPhone and iPad with Larger Text, Dark Interface, Sufficient Contrast, Differentiate Without Color Alone and Reduced Motion; Mac with the same minus Larger Text (Apple doesn't offer it on Mac: "This label isn't supported on Mac" in its overview of the labels). If Apple adds it, Corres can claim it on the Mac too (see the table). Apple only lets them be published once Corres is live on the App Store, so publish them right after launch. VoiceOver and Voice Control stay off until the hands-on check below. Apple Watch has no declaration yet.

## What's built for VoiceOver and Voice Control

- Every button has a name, including the icon-only ones. Swipe actions on a row are also VoiceOver actions ("Archive", "Move to Trash"), so no swipe is needed.
- Rotors: Unread and Flagged in the list, and Messages inside a conversation.
- Archive, Trash, Undo, Sending and a failed send are spoken when they happen, and Undo stays up for 15 seconds instead of 5 while VoiceOver or Switch Control is on.
- Voice Control answers to the words people say: "Tap Delete" works for Trash, "Tap Compose" for a new email, "Tap Filter" for Unread Only.
- The message body is named "Message", so "Tap Message" puts the cursor there.
- Siri can archive, reply, forward, write, send and search (Batch 2), which helps Voice Control users most of all.

## Hands-on check (before claiming VoiceOver and Voice Control)

On an iPhone with VoiceOver on (Settings > Accessibility > VoiceOver), do each common task above without looking. Then do the same with Voice Control on, by voice only, using "Show names" and "Show numbers" when a button's name isn't obvious. Repeat on the iPad, and on the Mac with VoiceOver (Command-F5). Anything that can't be done goes in an issue before the label is claimed.

## Automated audit

`Tests/AccessibilityAudit` runs Apple's own accessibility audit on the list, a conversation, Compose, Mailboxes and Settings with sample mail. Run it before each release, at the default text size and at the largest one (see its README). As of October 21, 2026 its remaining findings are all on Apple's own navigation bar buttons (Cancel, Send, Edit, Done, which iOS keeps fixed-size and offers through the Large Content Viewer), on disabled buttons, or on glass where rows pass beneath the floating search field.
