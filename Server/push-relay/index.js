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
  if (!deviceToken) {
    res.status(400).send('deviceToken is required');
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

functions.http('corresPushRelay', async (req, res) => {
  if (req.method !== 'POST') {
    res.status(405).send('POST only');
    return;
  }
  switch (req.path) {
    case '/register': return handleRegister(req, res);
    case '/unregister': return handleUnregister(req, res);
    case '/pubsub': return handlePubSub(req, res);
    default: res.status(404).send('Unknown route');
  }
});
