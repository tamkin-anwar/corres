# iCloud Mail and the next providers

Research for adding iCloud Mail (and what comes after it), 2026-10-15.
Nothing here is built yet; it needs one decision from Tamkin (below).

## How iCloud Mail can be reached

- **No API, no OAuth, no webhooks.** iCloud Mail is plain IMAP
  (`imap.mail.me.com:993`) and SMTP (`smtp.mail.me.com:587`). Third-party
  apps sign in with the person's Apple Account email and an
  **app-specific password** they make at account.apple.com. Apple's own
  push channel for iCloud Mail is private to Apple Mail.
- **IMAP can't push to an iPhone app by itself.** IMAP IDLE needs a
  connection held open, and iOS suspends third-party apps in the
  background. `BGAppRefreshTask` runs when iOS decides, sometimes hours
  apart, sometimes once a day.

So iCloud forces the one trade-off Gmail and Outlook didn't: **instant
notifications need a server that can log in to the mailbox.** Gmail and
Outlook avoided it because Google and Microsoft push a content-free "mailbox
changed" signal to Corres's relay. iCloud has nothing like that.

## What other apps do

| App | iCloud approach | Cost to privacy |
|---|---|---|
| Apple Mail | Apple's private push | None (Apple only) |
| Spark | Stores IMAP credentials (encrypted) on Readdle's servers to watch the mailbox; keeps encrypted notification snippets for 4 hours | Server holds a key to the mailbox |
| Airmail | Stores credentials on its servers only when "Real-Time Mailbox Monitoring" is on | Same, but opt-in |
| Canary | Lets people turn push off to avoid server components | Opt-in |

## Options for Corres

1. **On this iPhone only.** The app-specific password stays in the
   Keychain. Mail is live while Corres is open (IDLE), refreshes when iOS
   allows in the background, and catches up instantly on open.
   Notifications for iCloud are late or missing. The privacy story stays
   exactly as it is today.
2. **Relay watches every iCloud account.** The relay keeps an IDLE
   connection per account and sends Corres a push on new mail. Instant
   notifications, but Corres's server holds a password that can read the
   whole mailbox. This breaks "our servers never touch your mail," the
   promise on the website and in the Google verification.
3. **Opt-in instant notifications (recommended).** Option 1 by default.
   Each iCloud account gets a clearly explained switch, "Instant
   notifications," that sends the app-specific password to the relay,
   encrypted with Google Cloud KMS. The relay only watches the Inbox for new
   message numbers and sends the same kind of wake-up push Outlook gets: no
   message content is stored, and the password is deleted the moment the
   switch goes off or the account is removed. App-specific passwords can be
   revoked at account.apple.com at any time, separately from the Apple
   Account password.

**Recommendation: option 3.** It matches Airmail's approach, keeps
Corres's default promise intact, and tells people exactly what changes if
they want speed. The privacy policy and website get one honest paragraph
for it. Gmail's Google verification isn't affected, since it only covers
Google data.

## What building it takes

- **An IMAP/SMTP engine in Swift.** Apple's open-source `swift-nio-imap`
  (Apache 2) for the protocol, plus a small SMTP sender. This is the bulk
  of the work, and it unlocks every IMAP provider at once, not just iCloud.
- **MailClient gets an IMAP backend.** Same pattern as Outlook: folders
  become labels, UIDVALIDITY/UID replace history ids, flags map to
  read/starred, "Archive" is iCloud's Archive folder.
- **Sign-in screen for app-specific passwords.** A short guide with a link
  to account.apple.com, since most people have never made one.
- **Relay (only for option 3).** A small always-on worker (Cloud Run, not
  Cloud Functions, since IDLE connections are long-lived), KMS-encrypted
  credentials, and Firestore records keyed like `graphSubscriptions`.
- **Account color:** iCloud already defaults to its brand blue
  (`AccountPreferences.brandTone`).

Rough size: the IMAP engine and iCloud account type are about two to three
weeks of work; the opt-in relay is about one more.

## After iCloud: which providers next

| Provider | How | Worth it? |
|---|---|---|
| **Yahoo / AOL Mail** | IMAP with Yahoo OAuth (Yahoo must approve the app for mail access) | Yes: large, older user base; comes almost free once IMAP exists |
| **Any IMAP account** (custom domains, Fastmail, Zoho, GMX, school or ISP mail) | Server + password, or app password | Yes: one "Other" option covers the long tail |
| **Fastmail** | JMAP API with OAuth (partner program), real push via EventSource | Later: small but loyal paying users; a native JMAP backend beats IMAP |
| **Proton Mail** | Only through Proton Bridge on a desktop; no IMAP on phones | No: not possible on iPhone |
| **Exchange on-premises** | EWS is being retired; Microsoft 365 already works through Graph | No |

Suggested order: iCloud (with the IMAP engine) → "Other IMAP" → Yahoo/AOL
OAuth → Fastmail JMAP.

## Sources

- [Push email (Wikipedia)](https://en.wikipedia.org/wiki/Push_email)
- [Push Comes to Dove (Colin Cogle)](https://colincogle.name/blog/dovecot-with-apple-push/)
- [iCloud IMAP and SMTP settings](https://aiemaily.com/blog/icloud-mail-imap-smtp-settings)
- [Spark: privacy explained](https://support.readdle.com/spark/privacy/privacy-explained)
- [Spark: can't receive push notifications](https://sparkmailapp.com/help/troubleshooting/can-t-receive-push-notifications)
- [Spark Mail stores credentials in cloud (Michael Tsai)](https://mjtsai.com/blog/2016/12/01/spark-mail-stores-credentials-in-cloud/)
- [Mac Power Users: Spark stores credentials](https://talk.macpowerusers.com/t/spark-stores-email-account-credentials-on-their-servers/20388)
- [Airmail for iPhone review (MacStories)](https://www.macstories.net/reviews/airmail-for-iphone-review-power-user-email/)
- [Apple Developer Forums: BGAppRefreshTask best practices](https://developer.apple.com/forums/thread/729824)
- [Apple Developer Forums: how accurate is BGTaskScheduler](https://developer.apple.com/forums/thread/738991)
- [Apple Developer Forums: refreshing notification content](https://developer.apple.com/forums/thread/125912)
- [MacRumors: Apple Mail push for Gmail](https://forums.macrumors.com/threads/apple-mail-push-notifications-for-gmail.2393699/)
