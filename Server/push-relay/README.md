# Corres push relay

What this is and why it exists: [Docs/Architecture.md](../../Docs/Architecture.md)'s "Push notifications" entry. Short version: Gmail and Outlook can only deliver change notifications to a server you own (there is no client-only path), and this is the smallest server that could do that job. It never sees message content: Gmail's notification is just `{ emailAddress, historyId }` and Microsoft Graph's names a subscription and a message id.

What it sends: every registered device gets a silent wake-up (`content-available`, priority 5) so Corres syncs for itself. Where the app asked for alerts (`alerts: "1"` for Outlook and iCloud, `gmailAlerts: "1"` for Gmail once Apple grants notification filtering), it also sends a visible alert (`mutable-content`, priority 10) whose title is the localization key `"New email"` (`title-loc-key`, shown in the person's language from the app's `Localizable.strings`), whose body is the account's address, and which carries only the account and the message id (or Gmail's `historyId`). The notification extension fetches the email on the device and replaces that text with the sender and subject. Nothing from a message passes through here.

Everything below is a one-time setup. None of it can be done from inside this repo alone; it needs your own Google Cloud project and Apple Developer account.

## 1. Google Cloud project

1. Create a GCP project (or reuse one), and enable billing. At Corres's expected volume this should run within the free tier (2M Cloud Functions invocations/month, comparable Pub/Sub allowance), but billing must still be enabled to deploy.
2. Enable these APIs: Cloud Functions, Cloud Pub/Sub, Cloud Firestore, Cloud Build.
3. Create a Firestore database (Native mode, any region): this is where device-token-to-email mappings live. No message content is ever stored here, only `{ emailAddress, deviceToken }`.
4. Create a Pub/Sub topic, e.g. `gmail-push`. Gmail publishes to this topic when a watched mailbox changes; grant `gmail-api-push@system.gserviceaccount.com` the **Pub/Sub Publisher** role on it (Gmail's own documented requirement for `users.watch`).

## 2. Apple Push Notification service (APNs) auth key

1. In your Apple Developer account: Certificates, Identifiers & Profiles → Keys → create a new key with the **Apple Push Notifications service (APNs)** capability enabled. Download the `.p8` file once; Apple does not let you download it again.
2. Note the **Key ID** (shown when you create the key) and your **Team ID** (top-right of the Apple Developer portal).
3. Store the `.p8` file's contents as a Secret Manager secret in your GCP project, e.g.:
   ```bash
   gcloud secrets create corres-apns-auth-key --data-file=AuthKey_XXXXXXXXXX.p8
   ```

## 3. Deploy the relay

From this directory:

```bash
export APNS_KEY_ID=<the Key ID from step 2>
export APNS_TEAM_ID=<your Apple Developer Team ID>
export APNS_BUNDLE_ID=studio.anwarcreative.corres
export ICLOUD_KEY_VERSION=<the iCloud watcher's KMS key version>
npm run deploy
```

There is no production/development switch: each device says which APNs server its token belongs to (`apnsEnvironment`) when it registers, and devices registered before that are tried on production, then development, and the one that works is kept.

This deploys one HTTP Cloud Function (`corres-push-relay`) with these routes:
- `POST /register`: called by the app once a device grants notification permission, once per connected account. A `devices` document is keyed by device token and holds an `emailAddresses` array, not a single email: Corres supports multiple simultaneously-connected accounts (Batch 29), and one device can be registered for several accounts' pushes at once.
- `POST /unregister`: called with just a `deviceToken` when notifications are turned off entirely (removes the whole device record), or with `deviceToken` + `emailAddress` when a single account is disconnected while others stay connected (removes just that account from the list).
- `POST /attest-challenge` and `POST /attest`: App Attest, which lets the routes check that a call comes from a genuine Corres. See "App Attest (monitor mode)" below. Macs send a DeviceCheck token instead; see "DeviceCheck for the Mac (monitor mode)".
- `POST /register-graph`: an Outlook subscription the app made with Microsoft Graph itself: its id, a hash of its secret (`clientState`), the account, and the device. Graph's notices for that subscription wake only that device (each device makes its own subscription). An older subscription for the same account and device is deleted.
- `POST /icloud-key`, `POST /register-icloud`, `POST /unregister-icloud`: instant iCloud alerts. The app seals the app-specific password to the watcher's KMS key; the record keeps the address, server, user name and device for `Server/icloud-watcher`. An iCloud address (`icloud.com`, `me.com`, `mac.com`) may only name `imap.mail.me.com`.

`npm run deploy:graph` deploys `corres-push-relay-graph`, Microsoft Graph's notification target, with one instance kept warm (`--min-instances=1`), since Microsoft wants an answer within about three seconds. It reads every named subscription in one Firestore call and gives each APNs request 2.5 seconds.

These routes stay `--allow-unauthenticated`: there is no user-login system in Corres to authenticate these calls against, so they have to stay reachable by any anonymous app install. Real input validation (device-token/email format, a cap on how many accounts one device token can register) closes off the cheapest abuse, but this is *not* authentication on its own. App Attest is (see "App Attest (monitor mode)" below), once enforcement is turned on.

Note the deployed function's URL; it's the base URL the app needs.

## 4. Deploy the Pub/Sub push target as its own, authenticated function

The actual Gmail Pub/Sub push subscription target is a **separate** Cloud Function, `corres-push-relay-pubsub`, deployed *without* `--allow-unauthenticated` — found and fixed in a review sweep, this used to be a third route (`/pubsub`) on the same public function above, reachable by anyone who found the URL, with nothing checking the request actually came from Gmail's own Pub/Sub subscription. A single Cloud Function has one IAM invoker policy for its whole URL, so protecting just this one route meant giving it its own function.

```bash
npm run deploy:pubsub

# A dedicated service account Pub/Sub will sign its push requests as —
# not your own user account, and not the function's default runtime
# identity (which real callers could otherwise impersonate just by
# knowing its email).
gcloud iam service-accounts create gmail-push-invoker \
  --display-name="Gmail Pub/Sub push invoker"

# Only this service account may invoke the pubsub function; Google
# Cloud's own IAM layer enforces this before the function code ever
# runs — no hand-rolled JWT verification needed.
gcloud run services add-iam-policy-binding corres-push-relay-pubsub \
  --region=us-central1 \
  --member="serviceAccount:gmail-push-invoker@<PROJECT_ID>.iam.gserviceaccount.com" \
  --role="roles/run.invoker"

# Pub/Sub itself needs permission to mint OIDC tokens *as* that service
# account, granted to Pub/Sub's own service agent
# (service-<PROJECT_NUMBER>@gcp-sa-pubsub.iam.gserviceaccount.com —
# `gcloud projects describe <PROJECT_ID> --format="value(projectNumber)"`
# to find the project number).
gcloud iam service-accounts add-iam-policy-binding gmail-push-invoker@<PROJECT_ID>.iam.gserviceaccount.com \
  --member="serviceAccount:service-<PROJECT_NUMBER>@gcp-sa-pubsub.iam.gserviceaccount.com" \
  --role="roles/iam.serviceAccountTokenCreator"

# Point (or create) the subscription at the *pubsub* function's own URL,
# with --push-auth-service-account: this is what makes Pub/Sub attach a
# signed OIDC token to every push, which the IAM binding above then
# requires.
gcloud pubsub subscriptions create gmail-push-sub \
  --topic=gmail-push \
  --push-endpoint="<pubsub function URL>" \
  --push-auth-service-account="gmail-push-invoker@<PROJECT_ID>.iam.gserviceaccount.com"
```

Verify it actually rejects an unauthenticated caller before trusting it:
```bash
curl -o /dev/null -w "%{http_code}\n" -X POST "<pubsub function URL>" -d '{}'
# 403 — good. 204/404 means the function is still public; check the IAM binding above.
```

## 5. Wire the app to your deployment

Set `PushNotificationService.relayBaseURL` and `.pubsubTopicName` (in `App/PushNotificationService.swift`) to your deployed function's URL and `projects/<your-project-id>/topics/gmail-push`. These are placeholders in the committed code (pointing nowhere real) until you've completed the steps above; notifications silently no-op until they're set, the same "fails closed, not open" choice the rest of Corres already makes for anything not yet configured.

## What this deliberately does not do

- No message content ever passes through this service, in either direction. A push carries at most the account's address, a message id or `historyId`, and the `"New email"` key; never a subject, sender or body. The app fetches and displays the real content itself, on-device.
- No Gmail OAuth token ever reaches this service. The app itself calls `users.watch` (it already holds the token for every other Gmail API call); this relay only needs to know which device token belongs to which email address to route Gmail's contentless ping.
- Does not renew Gmail's watch subscription on its own. `users.watch` expires after 7 days; the app renews it at launch. An account that isn't opened for a week silently stops getting push until the next launch, a known, accepted gap, not a bug (see Docs/Architecture.md).
- Does not yet *require* proof that a call came from a genuine Corres install. It checks for that proof (App Attest, and DeviceCheck from Macs, below) and records the result, but in monitor mode it still accepts calls without it. Until enforcement is on, the format validation, the caps and the best-effort rate limits below remain the only barrier to a scripted caller.

## App Attest (monitor mode)

`/register`, `/unregister`, `/register-graph`, `/register-icloud` and `/unregister-icloud` can carry proof that the call comes from a genuine, unmodified Corres on real Apple hardware, using Apple's App Attest ([Establishing your app's integrity](https://developer.apple.com/documentation/devicecheck/establishing-your-app-s-integrity), [Validating apps that connect to your server](https://developer.apple.com/documentation/devicecheck/validating-apps-that-connect-to-your-server)). The checks live in `appattest.js`; the routes in `index.js`.

How it works:

1. Once per install, the app makes a key in the Secure Enclave (`DCAppAttestService.generateKey`), asks `POST /attest-challenge` for a one-time challenge (32 random bytes, good for five minutes, stored only as a hash in `attestChallenges`), and has Apple attest the key over `SHA256(challenge)`.
2. `POST /attest` with `{ keyId, attestation, challenge }` verifies all of Apple's steps: the certificate chain up to the pinned Apple App Attestation Root CA, the nonce in the leaf's `1.2.840.113635.100.8.2` extension equal to `SHA256(authData || SHA256(challenge))`, `SHA256(public key) == keyId`, the RP ID hash equal to `SHA256("7GGTC43CG8.studio.anwarcreative.corres")` (or the Mac debug build's `.debug` App ID), counter 0, aaguid `appattest` (production) or `appattestdevelop`, credential id equal to the key id, and on macOS the key's access policy. The public key, a zero counter, the environment and Apple's receipt are kept in `attestKeys`, keyed by the key id. A key already on file is never replaced.
3. Each later `register`/`unregister` gets a fresh challenge, puts it in the body as `attestChallenge`, and signs the exact body bytes: headers `Corres-Attest-Key` and `Corres-Attest-Assertion`. The relay checks the challenge (single use), the signature against the stored key over `SHA256(authenticatorData || SHA256(body))`, the RP ID, and that the counter went up, then stores the new counter.

The apps on TestFlight today (builds 35 and 36) sign only `/register` and `/unregister`, so the other three log `allowed unattested, none` for now. Their result goes on the Outlook subscription or iCloud watch record, never on the device record, so it can't hide whether `/register` was attested.

Monitor mode (the default): every checked call is logged on one line (`app attest /register: ok` or `app attest /register: allowed unattested, <reason>`), the device record gets `attested`, `attestReason`, `attestKeyId` and `attestCheckedAt`, and the call goes through either way. Reasons: `none` (no proof sent: an older build, the Simulator, a Mac without App Attest, or a key still being attested), `unknown-key`, `bad-challenge`, `bad-signature`, `replayed-counter`, `wrong-app`, `malformed`. The answer carries a `Corres-Attest-Result` header; on `unknown-key` the app makes and attests a new key. On the app side every failure (no support, no network, an Apple or relay error, Apple throttling) sends the call as before, so nobody loses notifications.

One-time setup: let Firestore delete unused challenges on its own:

```bash
gcloud firestore fields ttls update expiresAt --collection-group=attestChallenges --enable-ttl
```

Turning enforcement on, once the logs and device records show every current build attesting (`attested: true` on the devices still in use):

```bash
APP_ATTEST_ENFORCE=1 npm run deploy
```

Calls to the gated routes that neither App Attest nor DeviceCheck (below) vouches for then get 401 (`/register-graph` and the iCloud routes too, so the iPhone app would have to sign those first). Back to monitor mode with a plain `npm run deploy` (the script sets `APP_ATTEST_ENFORCE=0` unless told otherwise). Run through the enforcement checklist below before switching it on.

Other switches, set with `gcloud functions deploy corres-push-relay --update-env-vars=...`:
- `APP_ATTEST_NEW_KEYS=0` stops handing out challenges for new keys, so apps back off from Apple's attestation servers if Apple ever throttles Corres. Signed calls with existing keys keep working.
- `APP_ATTEST_DEVELOPMENT=0` refuses keys made in Apple's development environment. The iOS app's entitlement asks for production keys in every build, so this should only catch builds signed without it.

## DeviceCheck for the Mac (monitor mode)

Macs can't use App Attest: Apple says `DCAppAttestService.isSupported` is false on a Mac ([isSupported](https://developer.apple.com/documentation/devicecheck/dcappattestservice/issupported)), macOS 27 only adds it for full apps with the App Attest entitlement, and the Mac app doesn't have that entitlement. So the Mac proves itself with DeviceCheck instead ([DCDevice](https://developer.apple.com/documentation/devicecheck/dcdevice), macOS 10.15 and later; [server side](https://developer.apple.com/documentation/devicecheck/accessing-and-modifying-per-device-data)). The checks live in `devicecheck.js`.

How it works:

1. On every gated call (`/register`, `/unregister`, `/register-graph`, `/register-icloud`, `/unregister-icloud`) the Mac app asks `DCDevice.current.generateToken()` for a fresh token and sends it, base64, in the `Corres-Device-Check` header. Not supported, or any error, and the call goes without it, as before. iPhone and iPad builds never send it.
2. When App Attest didn't already vouch for the call, the relay posts the token to Apple's `POST /v1/validate_device_token` with `device_token`, a random `transaction_id` and a millisecond `timestamp`, signed with an ES256 JWT (`kid` the DeviceCheck key's id, `iss` the team, `iat` now; the same kind of token APNs takes). Production (`api.devicecheck.apple.com`) first; a 400 there is tried once on the development server (`api.development.devicecheck.apple.com`), where tokens from builds run from Xcode belong.
3. Apple's 200 means the token came from a real Apple device running an app signed by our team. The token's hash is then kept in `deviceCheckTokens` for a day; the same token sent again is refused (`replayed-token`), since Apple asks that each one be used once and the token isn't tied to the request the way an App Attest signature is.

What gets recorded: next to the App Attest fields, the device record (or Outlook subscription, or iCloud watch) gets `deviceChecked`, `deviceCheckReason` and `deviceCheckEnvironment`. The log line gets a note only when the call carried a token: `app attest /register: allowed unattested, none; devicecheck ok, production`, `...; devicecheck failed, <reason>` or `...; devicecheck not configured`. The answer carries `Corres-Device-Check-Result`. Reasons: `none` (no token sent), `not-configured`, `malformed`, `invalid-token` (Apple doesn't know it), `replayed-token`, `apple-auth` (Apple refused our key: not enabled for DeviceCheck, or the wrong key id or team), `apple-unavailable` (Apple busy, down or slow past five seconds), `not-needed` (App Attest already vouched), `error`.

If no DeviceCheck key is configured the relay logs `devicecheck not configured` once per instance and on each call that carries a token, never calls Apple, and behaves exactly as before.

What DeviceCheck does not prove: that the app is unmodified, or which of our team's apps made the token. It's weaker than App Attest, but it's what Apple offers Macs, and it's what Firebase App Check uses on a Mac by default ([FIRAppCheck.h](https://github.com/firebase/firebase-ios-sdk/blob/main/FirebaseAppCheck/Sources/Public/FirebaseAppCheck/FIRAppCheck.h)).

Turning it on:

1. In the Apple Developer portal, Certificates, Identifiers & Profiles, Keys: either edit the existing APNs key and tick **DeviceCheck** (the same `.p8` keeps working for both), or create a new key with only **DeviceCheck** ticked and download its `.p8` once. A separate key can be revoked without touching push; the shared one is one less secret.
2. A new key goes into Secret Manager (the shared APNs key is already there as `corres-apns-auth-key`):
   ```bash
   gcloud secrets create corres-devicecheck-key --data-file=AuthKey_XXXXXXXXXX.p8
   gcloud secrets add-iam-policy-binding corres-devicecheck-key \
     --member="serviceAccount:<the function's runtime service account>" \
     --role="roles/secretmanager.secretAccessor"
   ```
   The runtime service account is the one `corres-apns-auth-key` already grants access to (`gcloud functions describe corres-push-relay --region=us-central1 --format="value(serviceConfig.serviceAccountEmail)"`).
3. Deploy with the key's id (the team id comes from `APNS_TEAM_ID`):
   ```bash
   # A separate key:
   DEVICECHECK_KEY_ID=<its Key ID> DEVICECHECK_SECRET=corres-devicecheck-key npm run deploy
   # Or the APNs key with DeviceCheck ticked (the relay then reuses APNS_AUTH_KEY):
   DEVICECHECK_KEY_ID=$APNS_KEY_ID npm run deploy
   ```
   Keep passing these on every later deploy: the script sets every variable each time, and leaving `DEVICECHECK_KEY_ID` out turns DeviceCheck off again.
4. One-time, so Firestore clears used tokens on its own:
   ```bash
   gcloud firestore fields ttls update expiresAt --collection-group=deviceCheckTokens --enable-ttl
   ```
5. Check the logs for a Mac's `devicecheck ok, production`. `devicecheck failed, apple-auth` means the key isn't set up right.

`DEVICECHECK_DEVELOPMENT=0` (in the same deploy) stops trying the development server, so only TestFlight and App Store builds pass.

## Enforcement checklist

Before `APP_ATTEST_ENFORCE=1 npm run deploy`:

1. DeviceCheck is configured and the logs show `devicecheck ok` from Macs, not `not configured` or `apple-auth`.
2. Every iPhone and iPad device record still in use has `attested: true`, and every Mac one has `deviceChecked: true`. Records with neither are builds that would lose notifications.
3. The iPhone and iPad app signs `/register-graph`, `/register-icloud` and `/unregister-icloud` too (today it signs only `/register` and `/unregister`, so those three would get 401 on iOS). The Mac already sends DeviceCheck on all five.
4. The app copes with a 401 (it keeps the registration as not done and tries again later) and the current TestFlight and App Store builds are the ones that send proof.
5. Decide on the Simulator and Xcode builds: the Simulator can't attest or device check, so it would lose relay notifications. Development DeviceCheck tokens pass unless `DEVICECHECK_DEVELOPMENT=0`.
6. Have `APP_ATTEST_NEW_KEYS` ready (Apple throttling) and remember that a plain `npm run deploy` goes back to monitor mode.

## Limits, rate limits and cleanup

Caps (checked on every registration):
- 50 accounts per device (`/register` and `/register-graph`; registering an account the device already has is always fine), 50 Outlook subscriptions per device, 10 iCloud accounts per device.
- `ICLOUD_MAX_WATCHES` (default 2000) iCloud watches in all: past it, `/register-icloud` answers 503 for new watches. The count is an aggregation query, refreshed at most once a minute per instance. Set the same value on the watcher (its `npm run deploy` passes `ICLOUD_MAX_WATCHES` too), which holds back any watch past it.

Rate limits: `/attest-challenge` 60, `/register-graph` 60 and `/register-icloud` 30 calls a minute per caller address, answered with 429. They live in each instance's memory, so they only slow one busy caller; they are not a real limit. The caller's address is the last `X-Forwarded-For` entry (the one Google's front end adds).

The real fix for flooding is Cloud Armor in front of the function: an external Application Load Balancer with a serverless NEG for `corres-push-relay`, a security policy with a rate-based ban rule, and ingress limited to the load balancer:

```bash
gcloud compute network-endpoint-groups create corres-relay-neg --region=us-central1 \
  --network-endpoint-type=serverless --cloud-run-service=corres-push-relay
gcloud compute security-policies create corres-relay-armor
gcloud compute security-policies rules create 1000 --security-policy=corres-relay-armor \
  --expression="true" --action=rate-based-ban --rate-limit-threshold-count=120 \
  --rate-limit-threshold-interval-sec=60 --ban-duration-sec=600 --conform-action=allow \
  --exceed-action=deny-429 --enforce-on-key=IP
# Then a backend service with the NEG and --security-policy=corres-relay-armor, a URL map,
# an HTTPS proxy and forwarding rule, and the app pointed at the load balancer's address.
# Last, add --ingress-settings=internal-and-gclb to the deploy script, so the function's
# own URL stops answering the internet directly.
```

Cleanup:
- A device token APNs calls gone (410, or `BadDeviceToken` on both servers) deletes the device record, or the iCloud watch at the watcher.
- Outlook subscription records carry `expiresAt` (a week after the last registration; Graph's mail subscriptions last under three days and the app renews them well before). One-time setup, so Firestore clears the ones nobody renews:

```bash
gcloud firestore fields ttls update expiresAt --collection-group=graphSubscriptions --enable-ttl
```

- Records written before this change have no `expiresAt` and stay until their device renews (which adds it) or unregisters.

## iCloud watcher

`Server/icloud-watcher` holds one IMAP IDLE connection per real login (server, port and user name), not per address, and wakes only devices whose own password has signed in to that login (the one that opened the connection, one with the same password, or one that signed in once on its own). So a record naming someone else's address with another server or a wrong password can't take over their connection or send alerts to their devices. A record whose password the server refuses three times is deleted. Its own `failures` writes don't make it reconnect; only a new password or login does, and at most 10 sign-ins run at once.

## Gmail alerts while Corres is closed (waiting on Apple)

Gmail's push only says "this mailbox changed", which includes reads and
archives, so a visible alert per change needs a notification extension
that can stay silent. That takes Apple's notification filtering
entitlement (requested 2026-10-14). Everything else is built and deployed:

- `register` takes `gmailAlerts: "1"`; the device's `gmailAlertAccounts`
  then get a visible mutable-content push per Gmail change, naming the
  account and Gmail's `historyId` (`gmailHistory`), never mail content.
- The extension asks Gmail for new Inbox messages since the last history
  point it saw (kept in the App Group) and shows the newest, or delivers
  empty content to stay silent.

To switch on once Apple grants it: add
`com.apple.developer.usernotifications.filtering` = true to
`NotificationExtension/NotificationExtension.entitlements` (with the
capability on the `studio.anwarcreative.corres.notify` App ID), and add
`-D CORRES_NSE_FILTERING` to OTHER_SWIFT_FLAGS for the Corres and
CorresNotify targets. Builds without the flag keep asking for silent
wake-ups, so nothing changes until then.
