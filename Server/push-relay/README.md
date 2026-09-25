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

This deploys one HTTP Cloud Function (`corres-push-relay`) with two routes:
- `POST /register`: called by the app once a device grants notification permission, once per connected account. A `devices` document is keyed by device token and holds an `emailAddresses` array, not a single email: Corres supports multiple simultaneously-connected accounts (Batch 29), and one device can be registered for several accounts' pushes at once.
- `POST /unregister`: called with just a `deviceToken` when notifications are turned off entirely (removes the whole device record), or with `deviceToken` + `emailAddress` when a single account is disconnected while others stay connected (removes just that account from the list).

Both routes stay `--allow-unauthenticated`: there is no user-login system in Corres to authenticate these calls against, so they have to stay reachable by any anonymous app install. Real input validation (device-token/email format, a cap on how many accounts one device token can register) closes off the cheapest abuse, but this is *not* authentication — see "What this deliberately does not do" below.

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
- **Does not, and currently cannot, verify that a `/register`/`/unregister` call actually came from a genuine Corres install**, not just something shaped like one. Real authentication for these two routes — proving the caller is a real, unmodified copy of the app on genuine Apple hardware, without requiring a user-login system this app doesn't have — is what Apple's **App Attest** framework exists for, and would be the correct fix; it's real client-side + server-side work (a per-device attested key, a server-side verification call against Apple's attestation service) deliberately not built as part of this pass. Until then, the format validation and per-device registration cap in `index.js` raise the cost of casual abuse but are not a substitute for actual authentication — worth treating as a known, open gap, not a solved one.
