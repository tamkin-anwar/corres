// Corres push relay: forwards "something changed" from Gmail (Pub/Sub) and
// Outlook (Microsoft Graph) to the right device via APNs, and keeps the
// records the iCloud watcher reads. It never sees message content: Gmail's
// notice carries only { emailAddress, historyId }, Graph's only a message
// id. Every device gets a silent wake-up (content-available) so Corres
// syncs for itself; where the app asked for it, a visible alert too, which
// names only the account and the message id (or Gmail's historyId). Its
// title is the localization key "New email" and its body the address;
// the notification extension fetches the email on the device and fills
// in the sender and subject. See README.md and Docs/Architecture.md's
// "Push notifications" entry.
const functions = require('@google-cloud/functions-framework');
const { Firestore } = require('@google-cloud/firestore');
const { KeyManagementServiceClient } = require('@google-cloud/kms');
const crypto = require('crypto');
const http2 = require('http2');
const appAttest = require('./appattest');
const deviceCheck = require('./devicecheck');

const firestore = new Firestore();
const devices = firestore.collection('devices');
// Device records and iCloud watches carry `expiresAt`, 30 days after the
// device last registered, and Firestore's TTL policy deletes the ones
// nobody renews (see README): an old phone, a token iOS replaced, an app
// deleted without APNs saying so. The app registers again on every launch,
// and whenever it runs (opened, woken by a push or a background refresh)
// once 12 hours have passed (`renewWatchIfDue`), so a device in use never
// gets near it. Without the app running, Gmail's watch lapses in 7 days
// and Outlook's subscription in under 3 anyway.
const DEVICE_RECORD_LIFETIME_MS = 30 * 24 * 60 * 60 * 1000;
function deviceExpiry() {
  return Firestore.Timestamp.fromMillis(Date.now() + DEVICE_RECORD_LIFETIME_MS);
}
// Outlook (Microsoft Graph) subscriptions: subscription id → the account
// it watches and a hash of its secret (clientState). Only the hash is kept.
const graphSubscriptions = firestore.collection('graphSubscriptions');
// iCloud accounts watched for instant alerts, one record per account and
// device: the address, the device, and the app-specific password sealed
// on the iPhone with the watcher's public key. This function can't open
// it; only the icloud-watcher service can, through Cloud KMS.
const icloudWatches = firestore.collection('icloudWatches');
// The KMS key the passwords are sealed to (RSA_DECRYPT_OAEP_2048_SHA256):
// projects/<p>/locations/<l>/keyRings/<r>/cryptoKeys/<k>/cryptoKeyVersions/<v>
const ICLOUD_KEY_VERSION = process.env.ICLOUD_KEY_VERSION;
let kms = null;
let cachedPublicKey = null;

// App Attest (see appattest.js): one-time challenges, and each attested
// key's public half and counter, by key id (hex). Only keys, never mail.
const attestChallenges = firestore.collection('attestChallenges');
const attestKeys = firestore.collection('attestKeys');
// Monitor mode until this is "1": every call is checked and the result
// recorded and logged, but a call without (or failing) App Attest still
// goes through, so no tester loses notifications while it's watched.
const APP_ATTEST_ENFORCE = process.env.APP_ATTEST_ENFORCE === '1';
// "0" stops handing out challenges for new keys, so apps back off from
// Apple's attestation servers (Apple's advice if it ever throttles us).
const APP_ATTEST_NEW_KEYS = process.env.APP_ATTEST_NEW_KEYS !== '0';
// "0" refuses keys made by development builds without the production
// entitlement. TestFlight and App Store builds always make production keys.
const APP_ATTEST_DEVELOPMENT = process.env.APP_ATTEST_DEVELOPMENT !== '0';
const CHALLENGE_LIFETIME_MS = 5 * 60_000;

// DeviceCheck (see devicecheck.js): the Mac's proof, since Macs can't use
// App Attest. Set up when DEVICECHECK_KEY_ID and a key are configured
// (see README); otherwise every Mac call logs "devicecheck not configured"
// and goes as it did. Used tokens are kept by hash until `expiresAt`, so
// one can't be sent twice.
const DEVICECHECK = deviceCheck.configFrom(process.env);
if (!DEVICECHECK) console.log('devicecheck not configured');
const deviceCheckTokens = firestore.collection('deviceCheckTokens');

// A device token belongs to one of Apple's two APNs servers: development
// for a build run from Xcode, production for TestFlight and the App Store.
// Sent to the other one it fails with BadDeviceToken. The app says which
// when it registers (`apnsEnvironment`); devices registered before it did
// are tried on production, then development, and the one that works is kept.
const APNS_HOSTS = {
  production: 'api.push.apple.com',
  development: 'api.sandbox.push.apple.com',
};
const APNS_ENVIRONMENTS = Object.keys(APNS_HOSTS);

// APNs provider tokens (ES256 JWTs). Apple's rules: a token whose `iat` is
// more than an hour old is refused (ExpiredProviderToken, 403), and a new
// token more than once every 20 minutes on the same connection is refused
// too (TooManyProviderTokenUpdates, 429). So each instance signs one token,
// keeps it in memory for 50 minutes for every push and both APNs servers,
// then signs the next. Instances don't share one, and don't need to: each
// holds its own connections, and the 20-minute rule is per connection.
let cachedToken = null;
let cachedTokenIssuedAt = 0;
const TOKEN_LIFETIME_MS = 50 * 60 * 1000;
const TOKEN_MIN_AGE_MS = 20 * 60 * 1000;

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

// APNs called `rejected` expired (only a clock that's far off makes that
// happen inside 50 minutes). True when the push is worth sending again:
// the token is dropped so the next push signs a fresh one, or another push
// already did that. A token under 20 minutes old is kept, since replacing
// it that soon is what TooManyProviderTokenUpdates refuses; that push fails.
function renewExpiredAPNsToken(rejected) {
  if (cachedToken !== rejected) return true;
  if (Date.now() - cachedTokenIssuedAt < TOKEN_MIN_AGE_MS) {
    console.log('apns token called expired under 20 minutes old; kept');
    return false;
  }
  console.log('apns token called expired; signing a new one');
  cachedToken = null;
  return true;
}

// A silent, content-free wake-up push: no alert/sound/badge, just
// content-available so the app's background handler runs and syncs for
// itself. Background pushes must use apns-priority 5, not the default 10
// (Apple silently drops/throttles priority-10 background pushes).
// One connection per APNs server, kept open and reused: a new HTTP/2
// connection per push added a handshake to every one. Every request has a
// timeout and handles stream errors, so a stuck push can't hang or crash
// the function (and get the whole notice redelivered).
// Google drops an outbound connection after 20 idle minutes, and a
// function's CPU sleeps between requests, so a connection quiet for 10
// minutes is replaced rather than trusted, and a push that fails on a
// reused one is tried once more on a fresh connection.
const APNS_IDLE_MS = 10 * 60_000;
const apnsSessions = {};
function dropSession(environment) {
  const entry = apnsSessions[environment];
  delete apnsSessions[environment];
  if (entry) { try { entry.session.close(); } catch { /* already gone */ } }
}

function apnsSession(environment) {
  const entry = apnsSessions[environment];
  if (entry && !entry.session.closed && !entry.session.destroyed && Date.now() - entry.usedAt < APNS_IDLE_MS) {
    entry.usedAt = Date.now();
    return { session: entry.session, reused: true };
  }
  dropSession(environment);
  const session = http2.connect(`https://${APNS_HOSTS[environment]}`);
  const forget = () => { if (apnsSessions[environment] && apnsSessions[environment].session === session) delete apnsSessions[environment]; };
  session.on('error', forget);
  session.on('close', forget);
  session.on('goaway', forget);
  apnsSessions[environment] = { session, usedAt: Date.now() };
  return { session, reused: false };
}

// Each attempt may take 10 seconds. The Outlook path, which Microsoft
// wants answered within three seconds, passes a `deadline` (a time) instead:
// every attempt ends by it, none starts after it, and a timeout isn't retried.
const APNS_TIMEOUT_MS = 10_000;

async function apnsRequest(environment, deviceToken, headers, payload, deadline) {
  const attempt = () => {
    const timeoutMs = deadline ? Math.min(APNS_TIMEOUT_MS, deadline - Date.now()) : APNS_TIMEOUT_MS;
    if (timeoutMs <= 0) return Promise.resolve({ status: 0, reason: 'Timeout' });
    return apnsAttempt(environment, deviceToken, headers, payload, timeoutMs);
  };
  let result = await attempt();
  if (result.status === 0 && result.reused && !(result.reason === 'Timeout' && deadline)) {
    dropSession(environment);
    result = await attempt();
  }
  // Once more with a freshly signed token, if Apple says ours is stale.
  if (result.status === 403 && result.reason === 'ExpiredProviderToken' && renewExpiredAPNsToken(result.token)) {
    result = await attempt();
  }
  return result;
}

function apnsAttempt(environment, deviceToken, headers, payload, timeoutMs = APNS_TIMEOUT_MS) {
  return new Promise((resolve) => {
    let settled = false;
    const done = (result) => { if (!settled) { settled = true; resolve(result); } };
    let request;
    let reused = false;
    // The token this push carries, so an ExpiredProviderToken answer
    // replaces that one and not a newer one another push already signed.
    let token;
    try {
      const connection = apnsSession(environment);
      reused = connection.reused;
      token = buildAPNsToken();
      request = connection.session.request({
        ':method': 'POST',
        ':path': `/3/device/${deviceToken}`,
        authorization: `bearer ${token}`,
        'apns-topic': process.env.APNS_BUNDLE_ID,
        ...headers,
      });
    } catch {
      dropSession(environment);
      return done({ status: 0, reason: 'ConnectionError', reused });
    }
    request.setEncoding('utf8');
    request.setTimeout(timeoutMs, () => { request.close(); done({ status: 0, reason: 'Timeout', reused }); });
    request.on('error', () => done({ status: 0, reason: 'StreamError', reused }));
    let status = 0;
    let body = '';
    request.on('response', (h) => { status = h[':status']; });
    request.on('data', (chunk) => { body += chunk; });
    const finish = () => {
      let reason = null;
      try { reason = body ? JSON.parse(body).reason : null; } catch { reason = null; }
      done(status ? { status, reason, token } : { status: 0, reason: 'StreamClosed', reused });
    };
    request.on('end', finish);
    // A stream closed without an error or an end (the connection shut
    // cleanly under it) clears its own timeout, so without this the push
    // would never settle and the whole notice would hang until retried.
    request.on('close', finish);
    request.write(JSON.stringify(payload));
    request.end();
  });
}

function sendSilentPush(deviceToken, environment, deadline) {
  return apnsRequest(environment, deviceToken, { 'apns-push-type': 'background', 'apns-priority': '5' },
    { aps: { 'content-available': 1 } }, deadline);
}

// A visible alert for one new email, filled in on the iPhone by Corres's
// notification extension: the push names only the account and the
// message, never anything from it. "New email" is what shows if the
// extension can't fetch it in time: sent as a localization key, so iOS
// shows it in the person's language from the app's Localizable.strings
// (builds without the key show the key itself). Priority 10, and not throttled the way
// background pushes are, so it arrives as fast as the service's own app.
// For Gmail, whose notice names no message, `historyId` replaces
// `messageId`: the extension asks Gmail itself what's new since then, and
// stays silent if nothing is (Apple's notification filtering).
function sendAlertPush(deviceToken, environment, emailAddress, messageId, historyId, deadline) {
  return apnsRequest(environment, deviceToken, {
    'apns-push-type': 'alert',
    'apns-priority': '10',
    'apns-collapse-id': crypto.createHash('sha256').update(messageId || `${emailAddress}:${historyId}`).digest('hex').slice(0, 64),
  }, {
    aps: { alert: { 'title-loc-key': 'New email', body: emailAddress }, sound: 'default', 'mutable-content': 1 },
    account: emailAddress,
    ...(messageId ? { message: messageId } : { gmailHistory: String(historyId) }),
  }, deadline);
}

// Wakes one registered device through the server its token belongs to.
// A token Apple says is gone (410 Unregistered, after an app is deleted,
// or BadDeviceToken on both servers) is forgotten; one that fails on its
// server is tried on the other, in case it was registered wrongly, and the
// record is corrected. Never throws: a failed write is only logged, so one
// device can't fail a whole notice and get it redelivered to everyone.
async function wakeDevice(doc, alert, deadline) {
  const known = doc.data().apnsEnvironment;
  const order = APNS_ENVIRONMENTS.includes(known)
    ? [known, ...APNS_ENVIRONMENTS.filter((e) => e !== known)]
    : APNS_ENVIRONMENTS;
  let badEverywhere = true;
  for (const environment of order) {
    const { status, reason } = alert
      ? await sendAlertPush(doc.id, environment, alert.emailAddress, alert.messageId, alert.historyId, deadline)
      : await sendSilentPush(doc.id, environment, deadline);
    if (status === 200) {
      // An update, not a merge: it can't bring back a record deleted
      // meanwhile (unregistered, or expired) as one with no `expiresAt`.
      if (environment !== known) await quietly(doc.ref.update({ apnsEnvironment: environment }));
      return;
    }
    if (status === 410) {
      await quietly(doc.ref.delete());
      return;
    }
    // Only a wrong-server token is worth trying elsewhere; anything else
    // (throttling, a network error) will be the same on both.
    if (reason !== 'BadDeviceToken') { badEverywhere = false; return; }
  }
  if (badEverywhere) await quietly(doc.ref.delete());
}

async function quietly(promise) {
  try {
    await promise;
  } catch (error) {
    console.log('write failed', error && error.message);
  }
}

function environmentFrom(body) {
  const environment = body && body.apnsEnvironment;
  return APNS_ENVIRONMENTS.includes(environment) ? { apnsEnvironment: environment } : {};
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
// Outlook subscriptions one device can hold (one per account; an older one
// for the same account is deleted when a new one is registered).
const MAX_GRAPH_SUBSCRIPTIONS_PER_DEVICE = 50;
// iCloud watches in all, across every device: each one is an IMAP
// connection the single watcher instance holds open.
const MAX_ICLOUD_WATCHES = Number(process.env.ICLOUD_MAX_WATCHES) || 2000;

// Typed checks: a JSON array of one string passes RegExp.test (it's turned
// into that string), so every field is checked to be a string first.
function matches(value, pattern) {
  return typeof value === 'string' && pattern.test(value);
}

// Absent, or a well formed address. False for anything else.
function optionalEmail(value) {
  return value === undefined || value === null || value === '' || matches(value, EMAIL_PATTERN);
}

// ---- Best-effort rate limits ----------------------------------------------
// In memory, per instance, so only a brake on one busy caller, not a real
// limit (Cloud Armor in front of the function is that; see README). The
// caller's address is the last X-Forwarded-For entry, the one Google's
// front end adds; anything before it is whatever the caller sent.
const rateWindows = new Map(); // "route|ip" → { start, count }
const RATE_WINDOW_MS = 60_000;

function clientIP(req) {
  const forwarded = String(req.get('x-forwarded-for') || '').split(',').map((s) => s.trim()).filter(Boolean);
  return forwarded.length ? forwarded[forwarded.length - 1] : (req.ip || 'unknown');
}

// True (and a 429 sent) when this address has used up its calls for the minute.
function rateLimited(req, res, route, limit) {
  const now = Date.now();
  if (rateWindows.size > 20_000) {
    for (const [key, window] of rateWindows) if (now - window.start >= RATE_WINDOW_MS) rateWindows.delete(key);
    if (rateWindows.size > 20_000) rateWindows.clear();
  }
  const key = `${route}|${clientIP(req)}`;
  let window = rateWindows.get(key);
  if (!window || now - window.start >= RATE_WINDOW_MS) {
    window = { start: now, count: 0 };
    rateWindows.set(key, window);
  }
  window.count += 1;
  if (window.count <= limit) return false;
  res.status(429).set('Retry-After', '60').send('Too many requests');
  return true;
}

// App Attest routes and checks.

const CHALLENGE_PATTERN = /^[A-Za-z0-9+/]{43}=$/;
const KEY_ID_PATTERN = /^[A-Za-z0-9+/]{43}=$/;
const ATTESTATION_PATTERN = /^[A-Za-z0-9+/=]{100,16384}$/;
const ASSERTION_PATTERN = /^[A-Za-z0-9+/=]{40,1024}$/;

// A key id (base64 of 32 bytes) as its Firestore document id.
function keyDocID(keyId) {
  return Buffer.from(keyId, 'base64').toString('hex');
}

// 32 random bytes, good for one use within five minutes. Stored by its
// hash, so the database never holds a usable challenge. Unused ones are
// cleared by Firestore's TTL policy on `expiresAt` (see README). Each
// register or unregister call takes one, so a phone with many accounts
// asks for several at once; 60 a minute per address is far above that.
async function handleAttestChallenge(req, res) {
  if (rateLimited(req, res, '/attest-challenge', 60)) return;
  if (req.body && req.body.purpose === 'attest' && !APP_ATTEST_NEW_KEYS) {
    res.status(503).send('New App Attest keys are paused');
    return;
  }
  const challenge = crypto.randomBytes(32).toString('base64');
  await attestChallenges.doc(hash(challenge)).set({
    expiresAt: Firestore.Timestamp.fromMillis(Date.now() + CHALLENGE_LIFETIME_MS),
  });
  res.status(200).json({ challenge });
}

// True once for a challenge this relay issued and that hasn't expired;
// it's deleted as it's used, so a second use always fails.
async function consumeChallenge(challenge) {
  if (typeof challenge !== 'string' || !CHALLENGE_PATTERN.test(challenge)) return false;
  const ref = attestChallenges.doc(hash(challenge));
  return firestore.runTransaction(async (transaction) => {
    const doc = await transaction.get(ref);
    if (!doc.exists) return false;
    transaction.delete(ref);
    return doc.data().expiresAt.toMillis() > Date.now();
  });
}

// The app's new key, attested by Apple over one of our challenges. Once
// verified, its public key and a zero counter are kept for its assertions.
async function handleAttest(req, res) {
  const { keyId, attestation, challenge, platform } = req.body || {};
  if (typeof keyId !== 'string' || typeof attestation !== 'string'
      || !KEY_ID_PATTERN.test(keyId) || !ATTESTATION_PATTERN.test(attestation)) {
    res.status(400).send('keyId, attestation and challenge are required and must be well formed');
    return;
  }
  if (rateLimited(req, res, '/attest', 30)) return;
  if (!(await consumeChallenge(challenge))) {
    console.log('app attest /attest: rejected, bad-challenge');
    res.status(401).send('Challenge is unknown, used or expired');
    return;
  }
  let verified;
  try {
    verified = appAttest.verifyAttestation({
      attestation: Buffer.from(attestation, 'base64'),
      keyId: Buffer.from(keyId, 'base64'),
      challenge: Buffer.from(challenge, 'base64'),
      allowDevelopment: APP_ATTEST_DEVELOPMENT,
      platform: platform === 'macOS' ? 'macOS' : null,
    });
  } catch (error) {
    const reason = error instanceof appAttest.AttestError ? error.reason : 'error';
    console.log(`app attest /attest: rejected, ${reason}`);
    res.status(401).send('Attestation did not verify');
    return;
  }
  // A key is attested once: one already on file is never replaced.
  const ref = attestKeys.doc(keyDocID(keyId));
  const created = await firestore.runTransaction(async (transaction) => {
    if ((await transaction.get(ref)).exists) return false;
    transaction.create(ref, {
      publicKey: verified.publicKeyPem,
      appId: verified.appId,
      environment: verified.environment,
      counter: 0,
      // Kept for Apple's fraud metric (how many keys one device has made).
      receipt: verified.receipt ? verified.receipt.toString('base64') : null,
      validationCategory: verified.validationCategory ?? null,
      bundleVersion: verified.bundleVersion ?? null,
      platform: platform === 'macOS' ? 'macOS' : 'iOS',
      accessPolicy: verified.accessPolicy,
      createdAt: Firestore.FieldValue.serverTimestamp(),
    });
    return true;
  });
  if (!created) {
    console.log('app attest /attest: rejected, key-exists');
    res.status(409).send('Key already attested');
    return;
  }
  console.log(`app attest /attest: ok, ${verified.environment}, ${platform === 'macOS' ? 'macOS' : 'iOS'}, category ${verified.validationCategory ?? '?'}, policy ${verified.accessPolicy ?? 'none'}`);
  res.status(204).send();
}

// Whether this request carries a valid assertion from an attested key:
// the `Corres-Attest-Key` and `Corres-Attest-Assertion` headers, signed
// over the exact request body, which names a fresh challenge
// (`attestChallenge`). Never throws; says why when it isn't attested.
async function checkAssertion(req) {
  const keyId = req.get('Corres-Attest-Key');
  const assertion = req.get('Corres-Attest-Assertion');
  if (!keyId && !assertion) return { attested: false, reason: 'none' };
  if (!keyId || !assertion || !KEY_ID_PATTERN.test(keyId) || !ASSERTION_PATTERN.test(assertion)
      || !Buffer.isBuffer(req.rawBody)) {
    return { attested: false, reason: 'malformed' };
  }
  try {
    const ref = attestKeys.doc(keyDocID(keyId));
    if (!(await ref.get()).exists) return { attested: false, reason: 'unknown-key', keyId };
    if (!(await consumeChallenge(req.body && req.body.attestChallenge))) {
      return { attested: false, reason: 'bad-challenge', keyId };
    }
    // Checked and counted in one transaction, so two requests can't both
    // pass with the same counter.
    await firestore.runTransaction(async (transaction) => {
      const doc = await transaction.get(ref);
      const stored = doc.data();
      const { counter } = appAttest.verifyAssertion({
        assertion: Buffer.from(assertion, 'base64'),
        clientData: req.rawBody,
        publicKeyPem: stored.publicKey,
        appId: stored.appId,
        previousCounter: stored.counter,
      });
      transaction.update(ref, { counter, lastUsedAt: Firestore.FieldValue.serverTimestamp() });
    });
    return { attested: true, reason: null, keyId };
  } catch (error) {
    return { attested: false, reason: error instanceof appAttest.AttestError ? error.reason : 'error', keyId };
  }
}

// True the first time a DeviceCheck token's hash is seen, false after.
// Firestore's TTL policy on `expiresAt` clears old ones (see README).
async function markDeviceCheckTokenUsed(tokenHash, expiresAtMs) {
  try {
    await deviceCheckTokens.doc(tokenHash).create({ expiresAt: Firestore.Timestamp.fromMillis(expiresAtMs) });
    return true;
  } catch (error) {
    if (error && error.code === 6) return false; // ALREADY_EXISTS
    throw error;
  }
}

// The Mac's DeviceCheck token (`Corres-Device-Check`), checked with Apple
// only when App Attest didn't already vouch for the call.
async function checkDeviceCheck(req, attested) {
  const token = req.get('Corres-Device-Check');
  if (attested) return { deviceChecked: false, reason: token ? 'not-needed' : 'none', sent: Boolean(token) };
  const result = await deviceCheck.checkDeviceToken({ token, config: DEVICECHECK, markUsed: markDeviceCheckTokenUsed });
  return { ...result, sent: Boolean(token) };
}

// Added to the log line only when the call carried a DeviceCheck token,
// so iPhone and iPad lines read as before.
function deviceCheckNote(device) {
  if (!device.sent || device.reason === 'not-needed') return '';
  if (device.reason === 'not-configured') return '; devicecheck not configured';
  return device.deviceChecked ? `; devicecheck ok, ${device.environment}` : `; devicecheck failed, ${device.reason}`;
}

// One line per checked call, and in enforcement mode a 401 for anything
// neither App Attest (iPhone, iPad) nor DeviceCheck (Mac) vouches for.
// Returns null when the request was refused.
async function appAttestGate(req, res, route) {
  const result = await checkAssertion(req);
  const device = await checkDeviceCheck(req, result.attested);
  const note = deviceCheckNote(device);
  if (APP_ATTEST_ENFORCE && !result.attested && !device.deviceChecked) {
    console.log(`app attest ${route}: rejected, ${result.reason}${note}`);
    res.status(401).set('Corres-Attest-Result', result.reason);
    if (device.sent) res.set('Corres-Device-Check-Result', device.reason);
    res.send('App Attest or DeviceCheck required');
    return null;
  }
  console.log(`app attest ${route}: ${result.attested ? 'ok' : `allowed unattested, ${result.reason}`}${note}`);
  // Lets the app notice the relay no longer knows its key and attest again.
  res.set('Corres-Attest-Result', result.attested ? 'ok' : result.reason);
  if (device.sent) res.set('Corres-Device-Check-Result', device.deviceChecked ? 'ok' : device.reason);
  return { ...result, device };
}

// What's kept on the device record: whether its last call was attested
// (App Attest) or device checked (DeviceCheck, from a Mac).
function attestFields(result) {
  return {
    attested: result.attested,
    attestReason: result.reason,
    attestKeyId: result.keyId || null,
    attestCheckedAt: Firestore.FieldValue.serverTimestamp(),
    deviceChecked: result.device.deviceChecked,
    deviceCheckReason: result.device.reason,
    deviceCheckEnvironment: result.device.environment || null,
  };
}

// One device can now be signed into more than one Gmail account at once
// (Corres's own multi-account support), so a device token maps to a list of
// email addresses, not a single one: `emailAddresses` (array-contains
// queried in handlePubSub), not the old single `emailAddress` field.
// Registering the same account twice is a harmless no-op (arrayUnion only
// adds a value once).
async function handleRegister(req, res) {
  const { emailAddress, deviceToken, gmailAlerts } = req.body || {};
  if (!emailAddress || !deviceToken) {
    res.status(400).send('emailAddress and deviceToken are required');
    return;
  }
  if (!matches(deviceToken, DEVICE_TOKEN_PATTERN) || !matches(emailAddress, EMAIL_PATTERN)) {
    res.status(400).send('emailAddress or deviceToken is malformed');
    return;
  }
  if (rateLimited(req, res, '/register', 60)) return;
  const attest = await appAttestGate(req, res, '/register');
  if (!attest) return;
  if (await atAccountCap(deviceToken, emailAddress)) {
    res.status(429).send('Too many accounts registered for this device');
    return;
  }
  // "gmailAlerts": "1" only from builds whose notification extension can
  // stay silent when a Gmail change isn't new mail (Apple's filtering
  // entitlement). Everyone else keeps silent wake-ups.
  await devices.doc(deviceToken).set({
    emailAddresses: Firestore.FieldValue.arrayUnion(emailAddress),
    gmailAlertAccounts: gmailAlerts === '1'
      ? Firestore.FieldValue.arrayUnion(emailAddress)
      : Firestore.FieldValue.arrayRemove(emailAddress),
    updatedAt: Firestore.FieldValue.serverTimestamp(),
    expiresAt: deviceExpiry(),
    ...attestFields(attest),
    ...environmentFrom(req.body),
  }, { merge: true });
  res.status(204).send();
}

// Whether this device already has the most accounts it may, not counting
// this one (registering an account again is always fine).
async function atAccountCap(deviceToken, emailAddress) {
  const existing = await devices.doc(deviceToken).get();
  const current = (existing.exists && Array.isArray(existing.data().emailAddresses)) ? existing.data().emailAddresses : [];
  return current.length >= MAX_EMAIL_ADDRESSES_PER_DEVICE && !current.includes(emailAddress);
}

// With `emailAddress`, removes just that one account from the device's
// list (disconnecting a single account while others stay connected); the
// document itself is left in place even if the list becomes empty, since an
// empty `emailAddresses` array-contains-matches nothing anyway, and
// deleting it isn't necessary for correctness. Without `emailAddress`
// (turning notifications off entirely), the whole device record is removed.
async function handleUnregister(req, res) {
  const { deviceToken } = req.body || {};
  if (!matches(deviceToken, DEVICE_TOKEN_PATTERN)) {
    res.status(400).send('deviceToken is required and must be a valid device token');
    return;
  }
  if (!optionalEmail(req.body.emailAddress)) {
    res.status(400).send('emailAddress is malformed');
    return;
  }
  const emailAddress = req.body.emailAddress || null;
  if (rateLimited(req, res, '/unregister', 60)) return;
  const attest = await appAttestGate(req, res, '/unregister');
  if (!attest) return;
  if (emailAddress) {
    await devices.doc(deviceToken).set({
      emailAddresses: Firestore.FieldValue.arrayRemove(emailAddress),
      alertAccounts: Firestore.FieldValue.arrayRemove(emailAddress),
      gmailAlertAccounts: Firestore.FieldValue.arrayRemove(emailAddress),
      // The device is still there and still registering its other accounts.
      expiresAt: deviceExpiry(),
      ...attestFields(attest),
    }, { merge: true });
  } else {
    await devices.doc(deviceToken).delete();
  }
  // And this device's Outlook subscription records (an id and a hashed
  // secret), for that account or for every account when notifications go off.
  // And its iCloud watches: the sealed passwords go with it.
  await deleteICloudWatches(deviceToken, emailAddress);
  let subscriptions = graphSubscriptions.where('deviceToken', '==', deviceToken);
  if (emailAddress) subscriptions = subscriptions.where('emailAddress', '==', emailAddress);
  const found = await subscriptions.get();
  await Promise.all(found.docs.map((doc) => doc.ref.delete()));
  res.status(204).send();
}

// The target of the Gmail Pub/Sub push subscription. Pub/Sub retries on any
// non-2xx response, so a lookup/send failure for one device must not fail
// the whole request and trigger a redundant retry storm; each device is
// handled independently and the endpoint always acknowledges.
async function handlePubSub(req, res) {
  const dataBase64 = req.body && req.body.message && req.body.message.data;
  if (typeof dataBase64 !== 'string' || !dataBase64) {
    res.status(204).send();
    return;
  }
  let emailAddress;
  let historyId;
  try {
    ({ emailAddress, historyId } = JSON.parse(Buffer.from(dataBase64, 'base64').toString('utf8')));
  } catch {
    res.status(204).send();
    return;
  }
  if (!matches(emailAddress, EMAIL_PATTERN)) {
    res.status(204).send();
    return;
  }
  if (!(typeof historyId === 'string' && /^\d{1,20}$/.test(historyId)) && !(Number.isSafeInteger(historyId) && historyId > 0)) {
    historyId = null;
  }
  try {
    const found = await devices.where('emailAddresses', 'array-contains', emailAddress).get();
    const results = await Promise.allSettled(found.docs.map((doc) => {
      const alerting = historyId && (doc.data().gmailAlertAccounts || []).includes(emailAddress);
      return wakeDevice(doc, alerting ? { emailAddress, historyId } : undefined);
    }));
    logRejected('pubsub', results);
  } catch (error) {
    console.log('pubsub failed', error && error.message);
  }
  // Always acknowledged: a retry would wake every device again.
  res.status(204).send();
}

function logRejected(route, results) {
  const failed = results.filter((r) => r.status === 'rejected');
  if (failed.length) console.log(`${route}: ${failed.length} wake-ups failed`, failed[0].reason && failed[0].reason.message);
}

const SUBSCRIPTION_ID_PATTERN = /^[A-Za-z0-9-]{8,128}$/;
// Graph message ids: base64url-ish, a few hundred characters at most.
const MESSAGE_ID_PATTERN = /^[A-Za-z0-9+/=_-]{8,512}$/;
const CLIENT_STATE_PATTERN = /^[0-9a-f]{32,128}$/i;
const GRAPH_RECORD_LIFETIME_MS = 7 * 24 * 60 * 60 * 1000;

function hash(value) {
  return crypto.createHash('sha256').update(value).digest('hex');
}

// The app made an Outlook subscription with Graph itself (Graph checked
// this relay's URL as it did); it tells the relay which account that
// subscription watches and its secret, and which device to wake. The
// subscription record keeps that device, so Graph's notices for it wake
// only this device (each device makes its own subscription). An older
// subscription for the same account and device is deleted, so its
// notices, still coming until it expires at Microsoft, wake nothing.
async function handleRegisterGraph(req, res) {
  const { subscriptionId, clientState, emailAddress, deviceToken } = req.body || {};
  if (!matches(subscriptionId, SUBSCRIPTION_ID_PATTERN) || !matches(clientState, CLIENT_STATE_PATTERN)
      || !matches(emailAddress, EMAIL_PATTERN) || !matches(deviceToken, DEVICE_TOKEN_PATTERN)) {
    res.status(400).send('subscriptionId, clientState, emailAddress and deviceToken are required and must be well formed');
    return;
  }
  if (rateLimited(req, res, '/register-graph', 60)) return;
  const attest = await appAttestGate(req, res, '/register-graph');
  if (!attest) return;
  const [held, atCap] = await Promise.all([
    graphSubscriptions.where('deviceToken', '==', deviceToken).get(),
    atAccountCap(deviceToken, emailAddress),
  ]);
  const others = held.docs.filter((doc) => doc.data().emailAddress !== emailAddress);
  if (atCap || others.length >= MAX_GRAPH_SUBSCRIPTIONS_PER_DEVICE) {
    res.status(429).send('Too many accounts registered for this device');
    return;
  }
  // The device first, so a notice that arrives in between finds it.
  // "alerts": "1" from builds whose notification extension shows each new
  // email itself; anything else (older builds, notifications off for the
  // account) keeps the quiet background wake-up only. The device record's
  // App Attest fields are left to /register, which the app signs.
  const alerts = req.body.alerts === '1';
  await devices.doc(deviceToken).set({
    emailAddresses: Firestore.FieldValue.arrayUnion(emailAddress),
    alertAccounts: alerts ? Firestore.FieldValue.arrayUnion(emailAddress) : Firestore.FieldValue.arrayRemove(emailAddress),
    updatedAt: Firestore.FieldValue.serverTimestamp(),
    expiresAt: deviceExpiry(),
    ...environmentFrom(req.body),
  }, { merge: true });
  // `expiresAt` lets Firestore's TTL policy clear records nobody renews
  // (see README): Graph's mail subscriptions last under three days, and
  // the app renews them well before that.
  await graphSubscriptions.doc(subscriptionId).set({
    emailAddress, deviceToken, clientStateHash: hash(clientState), updatedAt: Firestore.FieldValue.serverTimestamp(),
    expiresAt: Firestore.Timestamp.fromMillis(Date.now() + GRAPH_RECORD_LIFETIME_MS),
    ...attestFields(attest),
  });
  const replaced = held.docs.filter((doc) => doc.id !== subscriptionId && doc.data().emailAddress === emailAddress);
  await Promise.all(replaced.map((doc) => quietly(doc.ref.delete())));
  res.status(204).send();
}

// Microsoft Graph's change notifications for Outlook mail. Graph first
// checks the URL by sending a validationToken, echoed back as plain text
// within 10 seconds. After that each notification names its subscription
// and carries the secret the app chose (clientState): only a match wakes
// the subscription's own device, so a guessed URL can't push anything.
// Like the Gmail path, nothing about the message itself is read or kept,
// and the endpoint always answers 202 so Graph doesn't retry.
//
// Graph counts a notice delivered only if the answer comes within 3
// seconds; it retries a slower one, and once more than 10% of answers in
// 10 minutes are slower it delays every notice by 10 minutes
// (learn.microsoft.com/graph/change-notifications-delivery-webhooks). So
// every APNs attempt ends by GRAPH_PUSH_MS and none starts after it, and
// the answer goes by GRAPH_ANSWER_MS at the latest, even if Firestore is
// still reading. It isn't answered first with the work after: this
// function has CPU only while it handles a request (request-based billing),
// so work after the answer would stall until the next request. Graph's 3
// seconds include the trip from Microsoft and any wait for an instance, so
// this leaves a second for those.
const GRAPH_PUSH_MS = 1_900;
const GRAPH_ANSWER_MS = 2_000;

async function handleGraph(req, res) {
  const validationToken = req.query && req.query.validationToken;
  if (validationToken) {
    // Graph's URL check: 200, text/plain, the decoded token, within 10
    // seconds. nosniff, so no browser reads the echoed text as a page.
    res.set('Content-Type', 'text/plain');
    res.set('X-Content-Type-Options', 'nosniff');
    res.status(200).send(String(validationToken));
    return;
  }
  const deadline = Date.now() + GRAPH_PUSH_MS;
  const work = wakeForGraph((req.body && Array.isArray(req.body.value)) ? req.body.value.slice(0, 100) : [], deadline)
    .then(() => true, (error) => { console.log('graph failed', error && error.message); return true; });
  let timer;
  const late = new Promise((resolve) => { timer = setTimeout(() => resolve(false), GRAPH_ANSWER_MS); });
  const finished = await Promise.race([work, late]);
  clearTimeout(timer);
  // Firestore was slow: anything still waiting sends nothing once it
  // resumes, since every push checks the deadline first.
  if (!finished) console.log('graph: answered before the work finished');
  res.status(202).send();
}

async function wakeForGraph(notifications, deadline) {
  const valid = notifications.filter((n) => n && matches(n.subscriptionId, SUBSCRIPTION_ID_PATTERN)
    && (typeof n.clientState === 'string' || typeof n.clientState === 'number'));
  if (valid.length === 0) return;
  // Every subscription in one read: Microsoft expects an answer within
  // three seconds.
  const ids = [...new Set(valid.map((n) => n.subscriptionId))];
  const docs = await firestore.getAll(...ids.map((id) => graphSubscriptions.doc(id)));
  const subscriptions = new Map(docs.filter((doc) => doc.exists).map((doc) => [doc.id, doc.data()]));
  // Each target (one device and account, or, for a record from before
  // records kept their device, every device of the account), and the new
  // messages Graph named for it (only ids).
  const targets = new Map();
  for (const notification of valid) {
    const subscription = subscriptions.get(notification.subscriptionId);
    if (!subscription || subscription.clientStateHash !== hash(String(notification.clientState))) continue;
    const { emailAddress } = subscription;
    if (typeof emailAddress !== 'string') continue;
    const deviceToken = matches(subscription.deviceToken, DEVICE_TOKEN_PATTERN) ? subscription.deviceToken : null;
    const key = `${deviceToken || '*'}|${emailAddress}`;
    if (!targets.has(key)) targets.set(key, { emailAddress, deviceToken, subscriptionId: notification.subscriptionId, messageIds: new Set() });
    // Only new mail alerts. Read, flagged, moved or deleted elsewhere
    // ("updated", "deleted") only wakes Corres quietly to catch up.
    const messageId = notification.resourceData && notification.resourceData.id;
    const isNew = (notification.changeType || 'created') === 'created';
    if (isNew && matches(messageId, MESSAGE_ID_PATTERN)) targets.get(key).messageIds.add(messageId);
  }
  // Everything in parallel, each push bounded by the deadline: the reply
  // waits for the pushes (see handleGraph for why they can't run after it).
  const results = await Promise.allSettled([...targets.values()].map(async (target) => {
    let found;
    if (target.deviceToken) {
      const device = await devices.doc(target.deviceToken).get();
      // The device turned notifications off (its record is gone, and so
      // is this subscription's use) or no longer has the account.
      if (!device.exists) {
        await quietly(graphSubscriptions.doc(target.subscriptionId).delete());
        return;
      }
      if (!(device.data().emailAddresses || []).includes(target.emailAddress)) return;
      found = [device];
    } else {
      found = (await devices.where('emailAddresses', 'array-contains', target.emailAddress).get()).docs;
    }
    await Promise.allSettled(found.map(async (device) => {
      const alerting = (device.data().alertAccounts || []).includes(target.emailAddress);
      const alerts = alerting
        ? [...target.messageIds].slice(0, 10).map((messageId) => wakeDevice(device, { emailAddress: target.emailAddress, messageId }, deadline))
        : [];
      // The quiet wake-up too, so Corres syncs in the background as before.
      await Promise.allSettled([...alerts, wakeDevice(device, undefined, deadline)]);
    }));
  }));
  logRejected('graph', results);
}

function watchID(emailAddress, deviceToken) {
  return hash(`${emailAddress.toLowerCase()}|${deviceToken.toLowerCase()}`);
}

// The public half of the watcher's key, for the iPhone to seal a password
// with: PKCS#1 DER, base64, the form iOS's SecKeyCreateWithData takes.
async function handleICloudKey(req, res) {
  if (!ICLOUD_KEY_VERSION) {
    res.status(503).send('Instant iCloud notifications are not set up');
    return;
  }
  if (!cachedPublicKey) {
    kms = kms || new KeyManagementServiceClient();
    const [key] = await kms.getPublicKey({ name: ICLOUD_KEY_VERSION });
    const der = crypto.createPublicKey(key.pem).export({ type: 'pkcs1', format: 'der' });
    cachedPublicKey = { key: der.toString('base64'), version: ICLOUD_KEY_VERSION.split('/').pop() };
  }
  res.status(200).json(cachedPublicKey);
}

// Turns instant alerts on for one iCloud account on one device. The
// password arrives sealed (RSA-OAEP, base64); a wrong or forged one just
// fails to sign in at the watcher, which then deletes it. The watcher
// keys each IMAP connection by its server and user name, and only wakes
// devices whose own password signed in, so a record naming someone else's
// address with another server or a wrong password can't silence or fake
// their alerts.
const HOST_PATTERN = /^(?=.{4,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/;
const SEALED_PATTERN = /^[A-Za-z0-9+/=]{300,700}$/;
const ICLOUD_HOST = 'imap.mail.me.com';
const ICLOUD_DOMAINS = new Set(['icloud.com', 'me.com', 'mac.com']);

// How many watches there are in all, counted at most once a minute per
// instance (an aggregation query, one read per thousand records).
let watchCount = { value: 0, at: 0 };
async function icloudWatchCount() {
  if (Date.now() - watchCount.at > 60_000) {
    const snapshot = await icloudWatches.count().get();
    watchCount = { value: snapshot.data().count, at: Date.now() };
  }
  return watchCount.value;
}

async function handleRegisterICloud(req, res) {
  const body = req.body || {};
  const { emailAddress, deviceToken, sealedPassword } = body;
  if (!matches(emailAddress, EMAIL_PATTERN) || !matches(deviceToken, DEVICE_TOKEN_PATTERN)
      || !matches(sealedPassword, SEALED_PATTERN)) {
    res.status(400).send('emailAddress, deviceToken and sealedPassword are required and must be well formed');
    return;
  }
  // Another IMAP account names its own server; iCloud's is the default,
  // and the only one an iCloud address may name. Only a public host name
  // on the IMAP-over-TLS port: never an address or a local name, so the
  // watcher can't be pointed inside a network.
  const optional = (value) => value === undefined || value === null || value === '';
  if (!(optional(body.imapHost) || typeof body.imapHost === 'string')
      || !(optional(body.imapPort) || typeof body.imapPort === 'string' || typeof body.imapPort === 'number')
      || !(optional(body.username) || typeof body.username === 'string')
      || !(optional(body.alerts) || typeof body.alerts === 'string')) {
    res.status(400).send('imapHost, imapPort, username and alerts must be strings');
    return;
  }
  const address = emailAddress.toLowerCase();
  const imapHost = (body.imapHost || ICLOUD_HOST).toLowerCase();
  const imapPort = Number(body.imapPort || 993);
  const username = body.username || emailAddress;
  if (!HOST_PATTERN.test(imapHost) || /^[\d.]+$/.test(imapHost) || imapHost.endsWith('.local')
      || imapHost.endsWith('.internal') || !(imapPort === 993) || username.length > 254) {
    res.status(400).send('imapHost must be a public host name on port 993');
    return;
  }
  if (ICLOUD_DOMAINS.has(address.split('@').pop()) && imapHost !== ICLOUD_HOST) {
    res.status(400).send(`iCloud addresses are watched on ${ICLOUD_HOST}`);
    return;
  }
  if (rateLimited(req, res, '/register-icloud', 30)) return;
  const attest = await appAttestGate(req, res, '/register-icloud');
  if (!attest) return;
  const ref = icloudWatches.doc(watchID(emailAddress, deviceToken));
  const [existing, current] = await Promise.all([
    icloudWatches.where('deviceToken', '==', deviceToken).get(),
    ref.get(),
  ]);
  const others = existing.docs.filter((doc) => doc.data().emailAddress !== address);
  if (others.length >= 10) {
    res.status(429).send('Too many iCloud accounts for this device');
    return;
  }
  if (!current.exists && await icloudWatchCount() >= MAX_ICLOUD_WATCHES) {
    console.log('icloud watches full');
    res.status(503).send('Instant iCloud notifications are full right now');
    return;
  }
  await ref.set({
    emailAddress: address,
    imapHost,
    imapPort,
    username,
    deviceToken,
    sealedPassword,
    alerts: body.alerts !== '0',
    failures: 0,
    updatedAt: Firestore.FieldValue.serverTimestamp(),
    expiresAt: deviceExpiry(),
    ...attestFields(attest),
    ...environmentFrom(body),
  });
  if (!current.exists) watchCount.value += 1;
  res.status(204).send();
}

async function handleUnregisterICloud(req, res) {
  const { deviceToken } = req.body || {};
  if (!matches(deviceToken, DEVICE_TOKEN_PATTERN)) {
    res.status(400).send('deviceToken is required');
    return;
  }
  if (!optionalEmail(req.body.emailAddress)) {
    res.status(400).send('emailAddress is malformed');
    return;
  }
  if (rateLimited(req, res, '/unregister-icloud', 30)) return;
  const attest = await appAttestGate(req, res, '/unregister-icloud');
  if (!attest) return;
  await deleteICloudWatches(deviceToken, req.body.emailAddress || null);
  res.status(204).send();
}

async function deleteICloudWatches(deviceToken, emailAddress) {
  if (emailAddress) {
    await icloudWatches.doc(watchID(emailAddress, deviceToken)).delete();
    return;
  }
  const found = await icloudWatches.where('deviceToken', '==', deviceToken).get();
  await Promise.all(found.docs.map((doc) => doc.ref.delete()));
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
    case '/attest-challenge': return handleAttestChallenge(req, res);
    case '/attest': return handleAttest(req, res);
    case '/register-graph': return handleRegisterGraph(req, res);
    case '/icloud-key': return handleICloudKey(req, res);
    case '/register-icloud': return handleRegisterICloud(req, res);
    case '/unregister-icloud': return handleUnregisterICloud(req, res);
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

// Outlook's notification target: public, because Microsoft Graph calls it
// with no Google identity; each notification is checked against its
// subscription's secret instead (see handleGraph).
functions.http('corresPushRelayGraph', async (req, res) => {
  if (req.method !== 'POST') {
    res.status(405).send('POST only');
    return;
  }
  return handleGraph(req, res);
});
