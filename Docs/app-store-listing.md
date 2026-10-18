# App Store listing for Corres 1.0

Drafted 2026-10-17. Everything here pastes into App Store Connect →
Corres → Distribution → iOS App 1.0. Character limits are Apple's; counts
are checked. Wording follows the website and stays provider-neutral:
Corres is its own mail app that works with Gmail and Outlook, not "a
Gmail client."

## App information

| Field | Value |
|---|---|
| Name (30) | **Corres** |
| Subtitle (30) | **Know what needs you** (19) |
| Primary category | Productivity |
| Secondary category | Business |
| Content rights | Does not contain third-party content |
| Age rating | 4+ (no restricted content; mail is the user's own) |
| Copyright | 2026 Tamkin Nurul Anwar (change to Anwar Creative Studio LLC once it exists) |
| Support URL | https://anwarcreativestudio.com/corres/support/ |
| Marketing URL | https://anwarcreativestudio.com/corres/ |
| Privacy Policy URL | https://anwarcreativestudio.com/corres/privacy/ (already set) |

## Promotional text (170)

Updatable any time without a new build.

> Gmail and Outlook in one inbox. Corres shows the emails that need a reply, tracks the ones waiting on someone else, and keeps your mail on your iPhone.

(151 characters)

## Description (4,000)

> Corres puts your Gmail and Outlook accounts in one inbox and sorts it for you. Emails that ask something of you go to Needs You. Emails you sent that haven't been answered go to Waiting. Newsletters, receipts and notifications stay out of the way until you want them.
>
> NEEDS YOU AND WAITING
> • Needs You holds the emails with a question, a decision or a deadline for you, and says why each one is there.
> • Waiting lists the emails you sent that haven't had a reply, and reminds you when it's time to follow up.
> • The Brief starts your day with a one-line summary and the few emails to read first.
>
> ALL YOUR ACCOUNTS
> • Gmail, Google Workspace, Outlook.com and Microsoft 365 in one inbox, or one account at a time.
> • Each account has its own color, name, signatures and notification settings.
> • Primary, Promotions, Social and Updates tabs that learn from the emails you move.
>
> NEW SENDERS
> • First emails from someone new can wait until you allow or block them.
> • Allow or block a whole company at once, and undo it if you change your mind.
>
> WRITING
> • Drafts, Send Later, Undo Send, and a reminder if nobody replies.
> • Several signatures, send-as addresses, and bold, lists and links.
> • Suggested replies and rewrites. Nothing is sent until you send it.
> • Write an email from the Share button in any app.
>
> ON-DEVICE INTELLIGENCE
> • Summaries, sorting and Ask (search your mail by asking a question) run on Apple Intelligence on your iPhone.
> • Receipts, deliveries and bills show the amount, date and order number at the top, on any iPhone.
>
> PRIVACY
> • Your email goes from Google or Microsoft straight to your iPhone and stays there. Our servers never receive it.
> • Remote images and tracking pixels are blocked until you allow them.
> • No ads. Your data is never sold or used to train AI.
>
> FREE AND PRO
> Mail is free: read, write, search and organize every account. Corres Pro adds the Brief, Needs You, Waiting, Ask, summaries and suggested replies. Pro starts with a free trial, then costs $20 a month or $200 a year. Subscriptions renew automatically unless you cancel at least 24 hours before the end of the period, in your iPhone's Settings. Lifetime is a one-time purchase of $1,000.
>
> Terms: https://anwarcreativestudio.com/corres/terms/
> Privacy: https://anwarcreativestudio.com/corres/privacy/

Prices match App Store Connect today ($20.00 monthly, $200.00 yearly,
$1,000 Lifetime, 2-week free trial). If they change, change them here too:
Apple wants subscription price and renewal terms stated.

## Keywords (100, comma-separated, no spaces)

```
inbox,email,mail,priority,screener,newsletter,summary,follow up,reply,triage,focus,private,brief
```

(96 characters.) No "Gmail" or "Outlook" in keywords: Apple rejects other
companies' trademarks there. Saying it works with them in the description
is fine.

## What's New (1.0)

> The first release of Corres.

## Screenshots

Required: **iPhone 6.9"** (1320 × 2868) and, since Corres runs on iPad,
**iPad 13"** (2064 × 2752). Up to 10 each; Apple shows the first 3 in
search, so those carry the pitch. Made from the Simulator with sample mail
(never real mail), with a short headline above each:

1. **Know what needs you.** Needs You with reasons on each row.
2. **Your day in one sentence.** The Brief.
3. **Every account, one inbox.** All Inboxes with Gmail and Outlook colors.
4. **New senders wait for a yes.** The Screener with People and Companies.
5. **Never lose a thread.** Waiting with a follow-up nudge.
6. **Summaries on your iPhone.** An email with its summary card.
7. **Private by design.** The Private by Design screen.

Claude can render these from the sample account at the exact sizes.

## App Review notes

> Corres is an email client. It works without signing in: on first launch, tap "Explore Corres" to see every screen with sample data.
>
> To test with a real account, add an Outlook.com or Microsoft 365 account in Settings → Add Account. Gmail sign-in works for Google test users only until Google finishes verifying the app; if you need a Gmail account, contact support@corres.app and we'll add one.
>
> Corres Pro (Brief, Needs You, Waiting, Ask, summaries) is an auto-renewable subscription with a free trial, plus a Lifetime purchase; use a Sandbox account to test.
>
> All mail is stored on the device. A push relay receives only "mailbox changed" signals from Google and Microsoft to wake the app; it never receives message content. Smart features use Apple's on-device Foundation Models.

Demo account: not needed (sample mail plus Outlook sign-in). Contact:
Tamkin Anwar, support@corres.app.

## Before submitting (blockers)

- Google verification done, or reviewers can't sign in to Gmail (Outlook
  and sample mail still work).
- Submit only a build from `Scripts/appstore.sh`, never a TestFlight one.
- EU DSA trader details, if selling in the EU.
- Account holder moved to the LLC, if launching as the studio.
