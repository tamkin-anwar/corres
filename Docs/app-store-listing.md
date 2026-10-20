# App Store listing for Corres 1.0

Drafted 2026-10-17, rewritten 2026-10-19 for Build 16, and for Build 17
(search past the first results, invitations, Corres in Home Screen
Search) (one home on Needs
You, no Brief, Ask in Search, iCloud and other accounts, offline changes,
iCloud sync). Everything here pastes into App Store Connect → Corres →
Distribution → iOS App 1.0. Character limits are Apple's; counts are
checked. Wording follows the website and stays provider-neutral: Corres
is its own mail app that works with Gmail, Outlook and iCloud, not "a
Gmail client." Platform wording says iPhone only until the Mac app ships.

## App information

| Field | Value |
|---|---|
| Name (30) | **Corres** |
| Subtitle (30) | **Mail that knows what needs you** (30, set in App Store Connect 2026-10-19) |
| Primary category | Productivity |
| Secondary category | Business |
| Content rights | Does not contain third-party content |
| Age rating | 4+ (no restricted content; mail is the user's own) |
| Copyright | 2026 Tamkin Nurul Anwar (change to Anwar Creative Studio LLC once it exists) |
| Support URL | https://anwarcreativestudio.com/corres/support/ |
| Marketing URL | https://anwarcreativestudio.com/corres/ |
| Privacy Policy URL | https://anwarcreativestudio.com/corres/privacy/ (already set) |

The three URLs move to https://corres.app/, /support/ and /privacy/
after Google verification clears; until then they stay where Google's
review has them.

## Promotional text (170)

Updatable any time without a new build.

> Gmail, Outlook, iCloud and more in one inbox. Corres opens on the emails that need you, says why, and keeps your mail on your iPhone.

(133 characters)

## Description (4,000)

> Corres opens on what needs you. Gmail, Outlook, iCloud and almost any other email account sit in one inbox, read and sorted on your iPhone. The emails that ask something of you come first, each with the reason it's there. The rest of your mail waits one swipe away, quiet until you're ready.
>
> NEEDS YOU AND WAITING
> • Needs You holds the emails with a question, a decision or a deadline for you, grouped into Due soon and When you can.
> • Waiting lists the emails you sent that haven't had a reply, and nudges you when it's time to follow up.
> • Done with one? Swipe it away. Wrong call? Press and hold to move it, and Corres learns.
>
> ALL YOUR ACCOUNTS
> • Gmail, Google Workspace, Outlook.com, Microsoft 365 and iCloud Mail, plus Yahoo, AOL, Fastmail, Zoho or a work server with just your address and password.
> • Primary, Promotions, Social and Updates, sorted by Corres and learning from the emails you move.
> • Each account has its own color, name, signatures and notification settings.
> • New Outlook and iCloud mail notifies you within seconds.
>
> NEW SENDERS
> • First emails from someone new wait until you allow or block them.
> • Allow or block a whole company at once, and undo it if you change your mind.
>
> SEARCH THAT ANSWERS
> • Search every account at once, archived mail included, with filters like from:, has:attachment and is:unread.
> • Ask a question like "when is my flight?" and get the answer from your own mail.
> • Find any conversation from Search on your Home Screen too.
>
> INVITATIONS
> • See when it is in your time zone, where, the video call to join, and whether you're free.
> • Accept, Maybe or Decline from the email, and add it to your calendar in a tap.
>
> WRITING
> • Drafts, Send Later, Undo Send, and a reminder if nobody replies.
> • Several signatures, send-as addresses, and bold, lists and links.
> • Suggested replies and rewrites. Nothing is sent until you send it.
> • Write an email from the Share button in any app.
>
> ANYWHERE
> • Archive, delete and flag with no signal. Your changes go through once you're back online.
> • What you sort, snooze, pin, allow and block follows you to your other devices through iCloud. Your email never does.
>
> SMART ON EVERY IPHONE
> • Needs You, its reasons, and key details like amounts, dates and order numbers work on every iPhone.
> • With Apple Intelligence, Corres also writes summaries and suggested replies, on the iPhone itself, and checks each one against the email before you see it.
>
> PRIVACY
> • Your email goes from your provider straight to your iPhone. Our servers never receive it.
> • Remote images and tracking pixels are blocked until you allow them, and Unsubscribe is one tap.
> • No ads. Your data is never sold or used to train AI.
>
> FREE AND PRO
> Mail is free: read, write, search and organize every account. Corres Pro adds Needs You, Waiting, answers in Search, summaries and suggested replies. Pro starts with a free trial, then costs $20 a month or $200 a year. Subscriptions renew automatically unless you cancel at least 24 hours before the end of the period, in your iPhone's Settings. Lifetime is a one-time purchase of $1,000.
>
> Terms: https://anwarcreativestudio.com/corres/terms/
> Privacy: https://anwarcreativestudio.com/corres/privacy/

(3199 characters)

Prices match App Store Connect today ($20.00 monthly, $200.00 yearly,
$1,000 Lifetime, 2-week free trial). If they change, change them here too:
Apple wants subscription price and renewal terms stated.

## Keywords (100, comma-separated, no spaces)

```
inbox,email,mail,priority,screener,newsletter,summary,follow up,reply,triage,focus,private,offline
```

(98 characters.) No "Gmail", "Outlook" or "iCloud" in keywords: Apple
rejects other companies' trademarks there. Saying it works with them in
the description is fine.

## What's New (1.0)

> The first release of Corres.

## Screenshots

Required: **iPhone 6.9"** (1320 × 2868) and, since Corres runs on iPad,
**iPad 13"** (2064 × 2752). Up to 10 each; Apple shows the first 3 in
search, so those carry the pitch. Made from the Simulator with sample mail
(never real mail), dark and light, 9:41, with a short headline above each:

1. **Know what needs you.** Needs You with Due soon, When you can and a reason on each row.
2. **Every account, one inbox.** Primary with Gmail, Outlook and iCloud colors.
3. **Ask your mail.** A question in Search with the answer above the results.
4. **Never lose a thread.** Waiting with a follow-up nudge.
5. **New senders wait for a yes.** New senders with Allow and Block.
6. **The details, up top.** An email with its summary and key details.
7. **Works anywhere.** Changes made offline, and iCloud sync between devices.
8. **Private by design.** The Private by Design screen.

Uploaded 2026-10-19, in `Docs/AppStore/`: six iPhone (App Store Connect's
required slot is now 6.3", 1206 × 2622, in `iphone-6.3/`; the 1320 × 2868
originals sit beside them) and three iPad 13" (2064 × 2752): Know what needs
you, Every account one inbox, Ask your mail, Invitations answered, Never lose
a thread, Private by design. Re-render with
`swift Scripts/RenderStoreShot.swift <capture> <out> "Headline." "Line under it."`
from Simulator captures of fresh sample mail (status bar at 9:41).

## App Review notes

> Corres is an email client. It works without signing in: on first launch, tap "Explore Corres" to see every screen with sample data.
>
> To test with a real account, add an Outlook.com, Microsoft 365, iCloud or other email account in Settings → Add Account. Gmail sign-in works for Google test users only until Google finishes verifying the app; if you need a Gmail account, contact support@corres.app and we'll add one.
>
> Corres Pro (Needs You, Waiting, answers in Search, summaries and suggested replies) is an auto-renewable subscription with a free trial, plus a Lifetime purchase; use a Sandbox account to test.
>
> Calendar access is optional and only asked for when you tap Check Your Calendar on an invitation; it is read on the device to show whether you're free, and never leaves it.
>
> All mail is stored on the device. A push relay receives only "mailbox changed" signals from Google and Microsoft to wake the app; it never receives message content. For iCloud, instant notifications are opt-in per account: the app-specific password is sealed on the iPhone so only our watcher service can open it, and the watcher only notices that new mail arrived, never reading a message. Smart features use Apple's on-device Foundation Models.

Demo account: not needed (sample mail plus Outlook sign-in). Contact:
Tamkin Anwar, support@corres.app.

## Before submitting (blockers)

- Google verification done, or reviewers can't sign in to Gmail (Outlook
  and sample mail still work).
- Submit only a build from `Scripts/appstore.sh`, never a TestFlight one.
- EU DSA trader details, if selling in the EU.
- Account holder moved to the LLC, if launching as the studio.
