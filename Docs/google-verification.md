# Google verification plan for Corres

Gmail sign-in for anyone outside the 100-person test list needs Google's
**restricted-scope verification** plus an annual **CASA security
assessment**. This is the plan, in order, with who does each step.

Started 2026-10-14. Google Cloud project: `corres-509320`.

## What Corres asks Google for

| Scope | Google's class | Why Corres needs it |
|---|---|---|
| `gmail.modify` | Restricted | Read, sort, archive, label, mark read, trash and send. The core of the app. |
| `gmail.settings.basic` | Restricted | Out of Office (vacation responder). Asked for only when the person opens Out of Office. |

`gmail.readonly` and `gmail.send` were dropped on 2026-10-14 (commit
4a66b8a) because `gmail.modify` covers both. Google rejects scopes an app
doesn't use.

Because Corres keeps mail on the device and the push relay never receives
mail, Google's own wording ("ability to access data from or through a
third-party server") gives Corres a case for skipping CASA. Developers
report Google has still required it for on-device apps, so plan on doing
it, and say plainly in the submission that no server stores or receives
Gmail data.

## Progress
- 2026-10-14: steps 1–3 done. Scopes trimmed to `gmail.modify` + `gmail.settings.basic`; Branding has the home, privacy and terms links and the authorized domain; `anwarcreativestudio.com` verified in Search Console (HTML file `google3cee5c276a72f1e6.html` at the site root; keep it there); home and terms pages live. Logo (the app icon at 120×120) uploaded too. Still open in step 1: the support/developer emails are the personal Gmail (the Cloud project is owned by it).

## Steps

### 1. Clean up the consent screen (Tamkin, 10 minutes)
In Google Cloud Console → Google Auth Platform (project `corres-509320`):
- **Data Access:** remove `gmail.readonly` and `gmail.send`. Keep `gmail.modify` and `gmail.settings.basic`, plus the basic `openid`, `email`, `profile`.
- **Branding:** app name **Corres**, the Corres icon (120×120), support email `support@corres.app`, developer contact email, and these links:
  - Home page: `https://anwarcreativestudio.com/corres/`
  - Privacy policy: `https://anwarcreativestudio.com/corres/privacy/`
  - Terms of service (optional but helps): `https://anwarcreativestudio.com/corres/terms/`
- **Authorized domains:** `anwarcreativestudio.com` (and `corres.app` if the home page moves there).

### 2. Prove the domain (Tamkin, 5 minutes)
Verify `anwarcreativestudio.com` in Google Search Console with the same Google account that owns the Cloud project. Brand verification fails without it.

### 3. A real Corres home page (Claude)
Google rejects a home page that's just a section of another site. Build
`anwarcreativestudio.com/corres/`: what Corres is, a clear link to the
privacy policy, and Google's required sentence:

> Corres's use and transfer of information received from Google APIs adheres to the Google API Services User Data Policy, including the Limited Use requirements.

Add simple Terms of Service at `/corres/terms/`. The privacy page already
has the Limited Use statement.

### 4. Demo video (Tamkin records, Claude scripts)
An unlisted YouTube video, English, screen recording on the iPhone with
captions or voice-over. It must show, in order:
1. Corres open, then **Settings → Add Account → Gmail**.
2. Google's consent screen, scrolled so **every scope is visible**, with the project name Corres. Then Allow.
3. `gmail.modify` in use: the inbox loading (read), opening an email, archiving one, applying a label, marking read/unread, moving one to Trash, then **sending** a reply.
4. `gmail.settings.basic` in use: **Settings → Out of Office**, Google's second consent prompt, turning the reply on and saving it.
5. A sentence on screen: *"Mail is stored and processed only on this iPhone. Corres's servers never receive Gmail data."*

### 5. Submit for verification (Tamkin, with Claude's text)
In Google Auth Platform → Verification Center → **Prepare for verification**. Paste these justifications:

**gmail.modify**
> Corres is an email client for iPhone. gmail.modify lets the user read their mail, organize it (archive, label, mark read or unread, move to Trash, report spam) and send and reply, all from the app. These are the core functions of an email client; a narrower scope can't support organizing mail. All Gmail data is fetched directly to the user's device and stored there; Corres's servers never receive, store or process Gmail content. Sorting and summaries run on the device.

**gmail.settings.basic**
> Used only for Out of Office: the user can turn their Gmail vacation responder on or off and set its message and dates from the app. Requested incrementally, only when the user opens Out of Office, never at sign-in.

**How data is handled (the "server" question)**
> Corres has no server that stores or processes Gmail data. Mail is downloaded over HTTPS straight from the Gmail API to the user's device and kept there, protected by iOS. An optional push relay (Google Cloud Functions) receives only Gmail's Pub/Sub notification (an email address and a historyId) and forwards a silent wake-up to the device; it never receives message content, metadata or OAuth tokens. Data is not used for advertising, sold, or used to train AI models.

### 6. CASA security assessment (Tamkin pays, Claude fixes findings)
When Google asks, use a Google-authorized CASA lab at **Tier 2**
(self-scan plus lab review). Expect roughly $540–$1,500 a year depending on
the lab, about 2–6 weeks, and a renewal every 12 months. What's in scope:
the iOS app and the push relay. Likely findings to have ready: TLS
everywhere (done), tokens in the Keychain (done), no secrets in the app
binary, dependency versions current, relay endpoints validating input
(done). Claude fixes anything the scan flags.

### 7. Publish to production
After approval, set the app's publishing status to **In production** and
remove the 100-user test-list limit. Re-verification happens yearly with
CASA.

## Until then
- Testers must be added as **test users** in the Cloud Console (up to 100).
- They'll see Google's "unverified app" screen and can continue past it.
- Outlook isn't affected by any of this; it has its own Microsoft verification (see the launch checklist).
