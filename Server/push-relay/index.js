// Corres push relay. One job only: forward Gmail's "something changed" ping
// to the right device via APNs. It never sees message content: Gmail's
// Pub/Sub notification for a mailbox change carries only { emailAddress,
// historyId }, and the push this sends is silent (content-available only,
// no alert text), so the actual subject/sender/body is fetched and shown
// entirely on-device, the same as any other sync. See Docs/Architecture.md's
// "Push notifications" entry for why this exists and what it deliberately
// does not do.
const functions = require('@google-cloud/functions-framework');
const { Firestore } = require('@google-cloud/firestore');
const crypto = require('crypto');
const http2 = require('http2');

const firestore = new Firestore();
const devices = firestore.collection('devices');

const APNS_HOST = process.env.APNS_PRODUCTION === 'true'
  ? 'api.push.apple.com'
  : 'api.sandbox.push.apple.com';

// APNs provider tokens (ES256 JWTs) are valid up to one hour; cached and
// rebuilt just under that so a burst of pushes doesn't re-sign one per push.
let cachedToken = null;
let cachedTokenIssuedAt = 0;
const TOKEN_LIFETIME_MS = 50 * 60 * 1000;

function base64url(input) {
  return Buffer.from(input).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

// Hand-rolled ES256 JWT: Node's built-in crypto module signs this directly,
// no third-party JWT library needed for a token this small and fixed-shape.
function buildAPNsToken() {
  const now = Date.now();
  if (cachedToken && now - cachedTokenIssuedAt < TOKEN_LIFETIME_MS) return cachedToken;

  const header = base64url(JSON.stringify({ alg: 'ES256', kid: process.env.APNS_KEY_ID }));
  const payload = base64url(JSON.stringify({ iss: process.env.APNS_TEAM_ID, iat: Math.floor(now / 1000) }));
  const signingInput = `${header}.${payload}`;
  const privateKey = crypto.createPrivateKey(process.env.APNS_AUTH_KEY);
  // APNs requires the raw (r || s) signature format, not DER, which is what
  // Node's 'sign' with dsaEncoding: 'ieee-p1363' produces directly.
  const signature = crypto.sign('sha256', Buffer.from(signingInput), { key: privateKey, dsaEncoding: 'ieee-p1363' });

  cachedToken = `${signingInput}.${base64url(signature)}`;
  cachedTokenIssuedAt = now;
  return cachedToken;
}

// A silent, content-free wake-up push: no alert/sound/badge, just
// content-available so the app's background handler runs and syncs for
// itself. Background pushes must use apns-priority 5, not the default 10
// (Apple silently drops/throttles priority-10 background pushes).
function sendSilentPush(deviceToken) {
  return new Promise((resolve) => {
    const client = http2.connect(`https://${APNS_HOST}`);
    client.on('error', () => resolve(false));
    const request = client.request({
      ':method': 'POST',
      ':path': `/3/device/${deviceToken}`,
      authorization: `bearer ${buildAPNsToken()}`,
      'apns-topic': process.env.APNS_BUNDLE_ID,
      'apns-push-type': 'background',
      'apns-priority': '5',
    });
    request.setEncoding('utf8');
    let status = 0;
    request.on('response', (headers) => { status = headers[':status']; });
    request.on('end', () => { client.close(); resolve(status === 200); });
    request.write(JSON.stringify({ aps: { 'content-available': 1 } }));
    request.end();
  });
}

// A real APNs device token is a 64-character hex string (32 raw bytes,
// hex-encoded — see PushNotificationService.didRegister's own
// `map { String(format: "%02x", $0) }`); rejecting anything else up front
// stops obviously-junk or malformed input from ever reaching Firestore.
// Not authentication — anyone can still send a syntactically valid-looking
// token for a device they don't own, since these endpoints have no way to
// verify who's actually calling them (see this file's own header comment)
// — but it closes off the cheapest, laziest abuse (garbage bodies, wrong
// types, SQL/NoSQL-injection-shaped strings) for free.
const DEVICE_TOKEN_PATTERN = /^[0-9a-f]{64}$/i;
// RFC 5322 is far more permissive than this, but every real Gmail address
// this actually needs to match fits comfortably inside it; deliberately
// simple over exhaustively correct for a validation check, not a parser.
const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
// A generous cap, not a realistic expectation: nobody has 50 Gmail accounts
// connected to one phone, but an unbounded array is an unbounded amount of
// Firestore document growth from repeated `register` calls against the same
// device token, whether malicious or just a client-side bug looping.
const MAX_EMAIL_ADDRESSES_PER_DEVICE = 50;

// One device can now be signed into more than one Gmail account at once
// (Corres's own multi-account support), so a device token maps to a list of
// email addresses, not a single one: `emailAddresses` (array-contains
// queried in handlePubSub), not the old single `emailAddress` field.
// Registering the same account twice is a harmless no-op (arrayUnion only
// adds a value once).
async function handleRegister(req, res) {
  const { emailAddress, deviceToken } = req.body || {};
  if (!emailAddress || !deviceToken) {
    res.status(400).send('emailAddress and deviceToken are required');
    return;
  }
  if (!DEVICE_TOKEN_PATTERN.test(deviceToken) || !EMAIL_PATTERN.test(emailAddress)) {
    res.status(400).send('emailAddress or deviceToken is malformed');
    return;
  }
  const existing = await devices.doc(deviceToken).get();
  const currentCount = (existing.exists && existing.data().emailAddresses) ? existing.data().emailAddresses.length : 0;
  if (currentCount >= MAX_EMAIL_ADDRESSES_PER_DEVICE) {
    res.status(429).send('Too many accounts registered for this device');
    return;
  }
  await devices.doc(deviceToken).set({
    emailAddresses: Firestore.FieldValue.arrayUnion(emailAddress),
    updatedAt: Firestore.FieldValue.serverTimestamp(),
  }, { merge: true });
  res.status(204).send();
}

// With `emailAddress`, removes just that one account from the device's
// list (disconnecting a single account while others stay connected); the
// document itself is left in place even if the list becomes empty, since an
// empty `emailAddresses` array-contains-matches nothing anyway, and
// deleting it isn't necessary for correctness. Without `emailAddress`
// (turning notifications off entirely), the whole device record is removed.
async function handleUnregister(req, res) {
  const { deviceToken, emailAddress } = req.body || {};
  if (!deviceToken || !DEVICE_TOKEN_PATTERN.test(deviceToken)) {
    res.status(400).send('deviceToken is required and must be a valid device token');
    return;
  }
  if (emailAddress) {
    await devices.doc(deviceToken).set({
      emailAddresses: Firestore.FieldValue.arrayRemove(emailAddress),
    }, { merge: true });
  } else {
    await devices.doc(deviceToken).delete();
  }
  res.status(204).send();
}

// The target of the Gmail Pub/Sub push subscription. Pub/Sub retries on any
// non-2xx response, so a lookup/send failure for one device must not fail
// the whole request and trigger a redundant retry storm; each device is
// handled independently and the endpoint always acknowledges.
async function handlePubSub(req, res) {
  const dataBase64 = req.body && req.body.message && req.body.message.data;
  if (!dataBase64) {
    res.status(204).send();
    return;
  }
  let emailAddress;
  try {
    ({ emailAddress } = JSON.parse(Buffer.from(dataBase64, 'base64').toString('utf8')));
  } catch {
    res.status(204).send();
    return;
  }
  if (emailAddress) {
    const matches = await devices.where('emailAddresses', 'array-contains', emailAddress).get();
    await Promise.all(matches.docs.map((doc) => sendSilentPush(doc.id)));
  }
  res.status(204).send();
}

// Deliberately two separate Cloud Functions sharing this one source file,
// not one function routing on `req.path` the way this used to. A single
// Cloud Function/Cloud Run service has exactly one IAM invoker policy for
// its *entire* URL — there is no way to require authentication on one path
// and leave another public on the same deployed service. `/register` and
// `/unregister` have to stay reachable by any anonymous app install (there
// is no user-login system to authenticate them against); `/pubsub` should
// only ever be reachable by Gmail's own Pub/Sub push subscription. Splitting
// them into `corresPushRelay` (still `--allow-unauthenticated`) and
// `corresPushRelayPubSub` (deployed *without* it, invoker access granted
// only to the Pub/Sub push subscription's own service account, which Google
// Cloud's own IAM layer enforces before this code ever runs — no hand-rolled
// JWT verification needed) is what actually makes that possible. Found and
// fixed in a review sweep: the single combined function had no request
// authentication on any route, meaning anyone who found the URL could POST
// directly to `/pubsub` and trigger a real APNs push to an arbitrary
// registered device.
functions.http('corresPushRelay', async (req, res) => {
  if (req.method !== 'POST') {
    res.status(405).send('POST only');
    return;
  }
  switch (req.path) {
    case '/register': return handleRegister(req, res);
    case '/unregister': return handleUnregister(req, res);
    default: res.status(404).send('Unknown route');
  }
});

functions.http('corresPushRelayPubSub', async (req, res) => {
  if (req.method !== 'POST') {
    res.status(405).send('POST only');
    return;
  }
  return handlePubSub(req, res);
});
