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

This deploys one HTTP Cloud Function (`corres-push-relay`) with three routes:
- `POST /register`: called by the app once a device grants notification permission, once per connected account. A `devices` document is keyed by device token and holds an `emailAddresses` array, not a single email: Corres supports multiple simultaneously-connected accounts (Batch 29), and one device can be registered for several accounts' pushes at once.
- `POST /unregister`: called with just a `deviceToken` when notifications are turned off entirely (removes the whole device record), or with `deviceToken` + `emailAddress` when a single account is disconnected while others stay connected (removes just that account from the list).
- `POST /pubsub`: the actual Pub/Sub push subscription target (below), never called directly by the app. Looks up devices via `array-contains` on `emailAddresses`.

Note the deployed function's URL; it's the base URL the app needs.

## 4. Point the Pub/Sub topic at the deployed function

```bash
gcloud pubsub subscriptions create gmail-push-sub \
  --topic=gmail-push \
  --push-endpoint="<function URL>/pubsub"
```

## 5. Wire the app to your deployment

Set `PushNotificationService.relayBaseURL` and `.pubsubTopicName` (in `App/PushNotificationService.swift`) to your deployed function's URL and `projects/<your-project-id>/topics/gmail-push`. These are placeholders in the committed code (pointing nowhere real) until you've completed the steps above; notifications silently no-op until they're set, the same "fails closed, not open" choice the rest of Corres already makes for anything not yet configured.

## What this deliberately does not do

- No message content ever passes through this service, in either direction. The push it sends carries no alert text, subject, sender, or body, `content-available` only. The app fetches and displays the real content itself, on-device, exactly like any other sync.
- No Gmail OAuth token ever reaches this service. The app itself calls `users.watch` (it already holds the token for every other Gmail API call); this relay only needs to know which device token belongs to which email address to route Gmail's contentless ping.
- Does not renew Gmail's watch subscription on its own. `users.watch` expires after 7 days; the app renews it at launch. An account that isn't opened for a week silently stops getting push until the next launch, a known, accepted gap, not a bug (see Docs/Architecture.md).
