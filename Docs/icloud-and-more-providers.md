# iCloud Mail and the next providers

Research for adding iCloud Mail (and what comes after it), 2026-10-15.
**Decided 2026-10-17: option 3, on-device by default with opt-in instant
notifications.** The build plan is at the end.

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

## Build plan (decided 2026-10-17)

### What competitors do, in short

| App | Default | Instant iCloud alerts | What its server keeps |
|---|---|---|---|
| Apple Mail | On device | Yes, Apple's private push (`XAPPLEPUSHSERVICE`) | Nothing extra |
| Spark | Server | Yes, always on, can't be turned off | Encrypted password; encrypted subject and preview for 4 hours |
| Canary | Fetch (on device) | Opt-in "Push" | Password, sender, subject, first line; deleted once delivered or when push is turned off |
| Airmail | On device | Opt-in "Real-Time Mailbox Monitoring" | Password, only while it's on |
| **Corres** | **On device** | **Opt-in per account** | **Encrypted password only; no subject, sender or preview, ever** |

Corres's version is stricter than every competitor: the relay sends the
same content-free wake-up Outlook gets, and the iPhone fetches and shows
the notification itself (the notification extension already does this for
Outlook). So the server never holds a single line of anyone's mail, only a
password the person can revoke at account.apple.com.

### What iCloud's server offers (checked 2026-10-17)

- Before login it advertises only `XAPPLEPUSHSERVICE` (Apple's private
  push), `AUTH=PLAIN` and `AUTH=XOAUTH2`. Apple gives third parties no
  OAuth for iCloud Mail, so sign-in is email + app-specific password.
- After login, reports conflict on IDLE, CONDSTORE and QRESYNC; MOVE is
  reportedly missing. The engine therefore asks for capabilities after
  login and uses what's there: IDLE if present, else short polling; COPY +
  delete + expunge when MOVE is missing; UID + flags comparison when
  CONDSTORE is missing.
- For comparison, Fastmail offers CONDSTORE, QRESYNC, MOVE and IDLE, and
  Yahoo offers MOVE, IDLE and OAuth. One engine has to handle both kinds.

### The shared email engine

Choice: **build on Apple's `swift-nio-imap`** (protocol parsing only;
Apache 2), with Corres's own connection, sync and SMTP layers on top.
- `SwiftMail` (BSD) is easier but requires iOS 18; Corres supports iOS 17,
  and it lacks CONDSTORE, which fast sync on Fastmail and others needs.
- `MailCore2` is unmaintained since 2020 and removed from some package
  managers for that reason.
- `swift-nio-imap`'s README still says "not production ready", so the
  parser gets its own test suite against recorded sessions from iCloud,
  Fastmail and Yahoo before shipping.

Pieces, in build order:
1. **`IMAPConnection`** (actor): TLS, login (PLAIN now, XOAUTH2 later for
   Yahoo/AOL), capability check, one command at a time, reconnect with
   backoff, IDLE while the app is open.
2. **`IMAPClient`**, the third `MailClient` backend next to Gmail and
   Outlook: list folders (SPECIAL-USE for Sent, Archive, Trash, Junk;
   name matching as a fallback), fetch headers newest first in batches,
   fetch bodies on demand, set flags, move, append to Sent when the server
   doesn't.
3. **Sync state** per folder: UIDVALIDITY, highest UID, and HIGHESTMODSEQ
   when CONDSTORE exists. A changed UIDVALIDITY means a full resync of that
   folder, the IMAP version of Gmail's expired history.
4. **Threads**: grouped by Message-ID, In-Reply-To and References, since
   IMAP has no thread ids.
5. **`SMTPClient`**: TLS, AUTH PLAIN, send the same RFC 5322 message
   `GmailMessageComposer` builds today.
6. **Sign-in screen**: "Add iCloud Mail" with the steps to make an
   app-specific password and a button that opens account.apple.com.
   Also "Other email" (server, port, username, password) once iCloud
   works, which covers custom domains, Fastmail, Zoho and most others.
7. **Background**: `BGAppRefreshTask` catch-up for everyone; instant
   alerts only for accounts that turn it on.

### Opt-in instant notifications

- **The switch**: Settings → the iCloud account → "Instant Notifications",
  off by default, with one plain sentence: "Corres's server keeps your
  app-specific password, encrypted, so it can tell this iPhone the moment
  mail arrives. It never reads or stores your email. Turn this off to
  delete it."
- **Relay**: a small always-on worker (Cloud Run with CPU always
  allocated; a 1 vCPU instance is roughly $6–20 a month and holds hundreds
  of IDLE connections). It logs in, selects INBOX, IDLEs, and on a new
  message sends the existing content-free push. It never FETCHes a message.
- **Password storage**: encrypted with Cloud KMS, decrypted only in the
  worker's memory; deleted the moment the switch goes off, the account is
  removed, or the login fails three times (the person revoked it).
- **Disclosure**: one paragraph in the privacy policy and on the support
  page; App Privacy label unchanged (credentials aren't "collected data"
  that's linked to identity beyond the email address already declared, but
  re-check the wording before submitting).

### Order and size

| Step | Work |
|---|---|
| 1 | IMAP engine + recorded-session tests | about 1 week |
| 2 | iCloud account: sign-in, sync, send, folders | about 1 week |
| 3 | Background refresh + notification extension for IMAP | 2–3 days |
| 4 | Opt-in relay worker + KMS + settings switch | 3–4 days |
| 5 | "Other email" (any IMAP server) | 2–3 days |
| 6 | Yahoo/AOL with OAuth (needs Yahoo's app approval) | later |

### Sources (added 2026-10-17)

- [Canary Mail privacy policy](https://canarymail.io/privacy-policy)
- [Canary: privacy standards](https://canarymail.io/help/secure-and-compliant-navigating-canary-mails-privacy-standards)
- [MacRumors: Canary Mail 3.0 thread](https://forums.macrumors.com/threads/canary-mail-3-0-has-been-released-no-subscription.2203446/)
- [Spark Classic troubleshooting](https://support.readdle.com/spark/troubleshooting)
- [Mozilla bug 1611624: IDLE with iCloud](https://bugzilla.mozilla.org/show_bug.cgi?id=1611624)
- [Apple forums: iCloud IMAP with QRESYNC and CONDSTORE](https://developer.apple.com/forums/thread/694251)
- [swift-nio-imap](https://swiftpackageregistry.com/apple/swift-nio-imap)
- [Announcing SwiftNIO IMAP](https://swift.org/blog/swift-nio-imap/)
- [SwiftMail](https://github.com/Cocoanetics/SwiftMail)
- [Introducing SwiftMail](https://www.cocoanetics.com/2025/03/introducing-swiftmail/)
- [MailCore2 on Swift Package Registry](https://swiftpackageregistry.com/MailCore/mailcore2)
- [nixpkgs: MailCore2 removed](https://code.ornl.gov/nix/nixpkgs/-/commit/cc3c0c7a679c794f119676abcb07cdc0d730f117)
- [Cloud Run pricing](https://goo.gle/3Inc1KA)
- [Cloud Run always-on CPU](https://oneuptime.com/blog/post/2026-02-17-how-to-configure-cloud-run-cpu-allocation-to-always-on-for-background-processing-workloads/markdown)
