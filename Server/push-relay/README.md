# Corres push relay

What this is and why it exists: [Docs/Architecture.md](../../Docs/Architecture.md)'s "Push notifications" entry. Short version: Gmail can only deliver change notifications to a server you own (there is no client-only path), and this is the smallest server that could do that job. It never sees message content: Gmail's notification is just `{ emailAddress, historyId }`, and this relay only ever forwards a silent, contentless wake-up push telling the app to sync for itself.

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
export APNS_PRODUCTION=false   # true only for an App Store / TestFlight build
npm run deploy
```

This deploys one HTTP Cloud Function (`corres-push-relay`) with these routes:
- `POST /register`: called by the app once a device grants notification permission, once per connected account. A `devices` document is keyed by device token and holds an `emailAddresses` array, not a single email: Corres supports multiple simultaneously-connected accounts (Batch 29), and one device can be registered for several accounts' pushes at once.
- `POST /unregister`: called with just a `deviceToken` when notifications are turned off entirely (removes the whole device record), or with `deviceToken` + `emailAddress` when a single account is disconnected while others stay connected (removes just that account from the list).
- `POST /attest-challenge` and `POST /attest`: App Attest, which lets the two routes above check that a call comes from a genuine Corres. See "App Attest (monitor mode)" below.

Both routes stay `--allow-unauthenticated`: there is no user-login system in Corres to authenticate these calls against, so they have to stay reachable by any anonymous app install. Real input validation (device-token/email format, a cap on how many accounts one device token can register) closes off the cheapest abuse, but this is *not* authentication on its own. App Attest is (see "App Attest (monitor mode)" below), once enforcement is turned on.

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

- No message content ever passes through this service, in either direction. The push it sends carries no alert text, subject, sender, or body, `content-available` only. The app fetches and displays the real content itself, on-device, exactly like any other sync.
- No Gmail OAuth token ever reaches this service. The app itself calls `users.watch` (it already holds the token for every other Gmail API call); this relay only needs to know which device token belongs to which email address to route Gmail's contentless ping.
- Does not renew Gmail's watch subscription on its own. `users.watch` expires after 7 days; the app renews it at launch. An account that isn't opened for a week silently stops getting push until the next launch, a known, accepted gap, not a bug (see Docs/Architecture.md).
- Does not yet *require* proof that a `/register`/`/unregister` call came from a genuine Corres install. It checks for that proof (App Attest, below) and records the result, but in monitor mode it still accepts calls without it. Until enforcement is on, the format validation and per-device registration cap remain the only barrier to a scripted caller.

## App Attest (monitor mode)

`/register` and `/unregister` can now carry proof that the call comes from a genuine, unmodified Corres on real Apple hardware, using Apple's App Attest ([Establishing your app's integrity](https://developer.apple.com/documentation/devicecheck/establishing-your-app-s-integrity), [Validating apps that connect to your server](https://developer.apple.com/documentation/devicecheck/validating-apps-that-connect-to-your-server)). The checks live in `appattest.js`; the routes in `index.js`.

How it works:

1. Once per install, the app makes a key in the Secure Enclave (`DCAppAttestService.generateKey`), asks `POST /attest-challenge` for a one-time challenge (32 random bytes, good for five minutes, stored only as a hash in `attestChallenges`), and has Apple attest the key over `SHA256(challenge)`.
2. `POST /attest` with `{ keyId, attestation, challenge }` verifies all of Apple's steps: the certificate chain up to the pinned Apple App Attestation Root CA, the nonce in the leaf's `1.2.840.113635.100.8.2` extension equal to `SHA256(authData || SHA256(challenge))`, `SHA256(public key) == keyId`, the RP ID hash equal to `SHA256("7GGTC43CG8.studio.anwarcreative.corres")` (or the Mac debug build's `.debug` App ID), counter 0, aaguid `appattest` (production) or `appattestdevelop`, credential id equal to the key id, and on macOS the key's access policy. The public key, a zero counter, the environment and Apple's receipt are kept in `attestKeys`, keyed by the key id. A key already on file is never replaced.
3. Each later `register`/`unregister` gets a fresh challenge, puts it in the body as `attestChallenge`, and signs the exact body bytes: headers `Corres-Attest-Key` and `Corres-Attest-Assertion`. The relay checks the challenge (single use), the signature against the stored key over `SHA256(authenticatorData || SHA256(body))`, the RP ID, and that the counter went up, then stores the new counter.

Monitor mode (the default): every checked call is logged on one line (`app attest /register: ok` or `app attest /register: allowed unattested, <reason>`), the device record gets `attested`, `attestReason`, `attestKeyId` and `attestCheckedAt`, and the call goes through either way. Reasons: `none` (no proof sent: an older build, the Simulator, a Mac without App Attest, or a key still being attested), `unknown-key`, `bad-challenge`, `bad-signature`, `replayed-counter`, `wrong-app`, `malformed`. The answer carries a `Corres-Attest-Result` header; on `unknown-key` the app makes and attests a new key. On the app side every failure (no support, no network, an Apple or relay error, Apple throttling) sends the call as before, so nobody loses notifications.

One-time setup: let Firestore delete unused challenges on its own:

```bash
gcloud firestore fields ttls update expiresAt --collection-group=attestChallenges --enable-ttl
```

Turning enforcement on, once the logs and device records show every current build attesting (`attested: true` on the devices still in use):

```bash
APP_ATTEST_ENFORCE=1 npm run deploy
```

Unattested `register`/`unregister` calls then get 401. Back to monitor mode with a plain `npm run deploy` (the script sets `APP_ATTEST_ENFORCE=0` unless told otherwise). Keep in mind before switching it on: devices that can't attest (the Simulator, and Macs, where `isSupported` is false today) would lose notifications, so enforcement for them needs a decision first.

Other switches, set with `gcloud functions deploy corres-push-relay --update-env-vars=...`:
- `APP_ATTEST_NEW_KEYS=0` stops handing out challenges for new keys, so apps back off from Apple's attestation servers if Apple ever throttles Corres. Signed calls with existing keys keep working.
- `APP_ATTEST_DEVELOPMENT=0` refuses keys made in Apple's development environment. The iOS app's entitlement asks for production keys in every build, so this should only catch builds signed without it.

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
