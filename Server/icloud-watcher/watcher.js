// Corres iCloud watcher: instant alerts for iCloud Mail, opt-in per
// account. Apple's own push for iCloud is private to Apple Mail, so this
// does what Apple Mail's servers do for it: holds one IMAP IDLE connection
// on each watched Inbox and wakes the person's iPhone the moment mail
// arrives.
//
// What it knows: the address, the device, and the app-specific password,
// sealed on the iPhone to this service's key and opened only here, in
// memory, through Cloud KMS. What it never does: fetch, read or keep a
// message. On new mail it asks only for the new message's number (its
// UID) and sends the same alert Outlook gets; the iPhone's notification
// extension fetches the email itself.
//
// Connections are keyed by the real login (server, port and user name),
// not by the address a record names, and a device is woken only once its
// own password has signed in to that login. So a record that names
// someone else's address with another server, or with a wrong password,
// can't take over their connection or send alerts to their devices.
//
// One instance (min = max = 1, CPU always on): two would watch every
// Inbox twice and alert twice.
const http = require('http');
const http2 = require('http2');
const crypto = require('crypto');
const { Firestore } = require('@google-cloud/firestore');
const { KeyManagementServiceClient } = require('@google-cloud/kms');
const { ImapFlow } = require('imapflow');

const firestore = new Firestore();
const watches = firestore.collection('icloudWatches');
const kms = new KeyManagementServiceClient();
const KEY_VERSION = process.env.ICLOUD_KEY_VERSION;
const ICLOUD_HOST = 'imap.mail.me.com';
// The most watches this instance holds (each login is one connection);
// the relay refuses new ones past the same number.
const MAX_WATCHES = Number(process.env.ICLOUD_MAX_WATCHES) || 2000;
// Sign-ins at once: a restart doesn't open every connection in the same
// second, which a mail server could take for abuse.
const MAX_CONCURRENT_LOGINS = 10;

const log = (...args) => console.log(new Date().toISOString(), ...args);

// ---- APNs (the same pushes the relay sends) ------------------------------

const APNS_HOSTS = { production: 'api.push.apple.com', development: 'api.sandbox.push.apple.com' };
let cachedToken = null;
let cachedTokenAt = 0;

function base64url(input) {
  return Buffer.from(input).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function apnsToken() {
  const now = Date.now();
  if (cachedToken && now - cachedTokenAt < 50 * 60 * 1000) return cachedToken;
  const header = base64url(JSON.stringify({ alg: 'ES256', kid: process.env.APNS_KEY_ID }));
  const payload = base64url(JSON.stringify({ iss: process.env.APNS_TEAM_ID, iat: Math.floor(now / 1000) }));
  const signature = crypto.sign('sha256', Buffer.from(`${header}.${payload}`),
    { key: crypto.createPrivateKey(process.env.APNS_AUTH_KEY), dsaEncoding: 'ieee-p1363' });
  cachedToken = `${header}.${payload}.${base64url(signature)}`;
  cachedTokenAt = now;
  return cachedToken;
}

// One connection per APNs server, kept open and reused, as the relay
// does: a connection quiet for 10 minutes is replaced rather than trusted,
// every request has a timeout and handles stream errors, and a push that
// fails on a reused connection is tried once more on a fresh one.
const APNS_IDLE_MS = 10 * 60_000;
const APNS_TIMEOUT_MS = 10_000;
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

async function apnsRequest(environment, deviceToken, headers, payload) {
  const first = await apnsAttempt(environment, deviceToken, headers, payload);
  if (first.status !== 0 || !first.reused) return first;
  dropSession(environment);
  return apnsAttempt(environment, deviceToken, headers, payload);
}

function apnsAttempt(environment, deviceToken, headers, payload) {
  return new Promise((resolve) => {
    let settled = false;
    const done = (result) => { if (!settled) { settled = true; resolve(result); } };
    let request;
    let reused = false;
    try {
      const connection = apnsSession(environment);
      reused = connection.reused;
      request = connection.session.request({
        ':method': 'POST', ':path': `/3/device/${deviceToken}`,
        authorization: `bearer ${apnsToken()}`, 'apns-topic': process.env.APNS_BUNDLE_ID, ...headers,
      });
    } catch {
      dropSession(environment);
      return done({ status: 0, reason: 'ConnectionError', reused });
    }
    request.setEncoding('utf8');
    request.setTimeout(APNS_TIMEOUT_MS, () => { request.close(); done({ status: 0, reason: 'Timeout', reused }); });
    request.on('error', () => done({ status: 0, reason: 'StreamError', reused }));
    let status = 0;
    let body = '';
    request.on('response', (h) => { status = h[':status']; });
    request.on('data', (c) => { body += c; });
    request.on('end', () => {
      let reason = null;
      try { reason = body ? JSON.parse(body).reason : null; } catch { reason = null; }
      done({ status, reason });
    });
    request.write(JSON.stringify(payload));
    request.end();
  });
}

// "New email" is a localization key: iOS shows it in the person's
// language from the app's Localizable.strings, and the notification
// extension replaces it with the sender and subject when it can.
function push(deviceToken, environment, alert) {
  const headers = alert
    ? { 'apns-push-type': 'alert', 'apns-priority': '10',
        'apns-collapse-id': crypto.createHash('sha256').update(alert.messageId).digest('hex').slice(0, 64) }
    : { 'apns-push-type': 'background', 'apns-priority': '5' };
  return apnsRequest(environment, deviceToken, headers, alert
    ? { aps: { alert: { 'title-loc-key': 'New email', body: alert.emailAddress }, sound: 'default', 'mutable-content': 1 },
        account: alert.emailAddress, message: alert.messageId }
    : { aps: { 'content-available': 1 } });
}

// Through the device's own APNs server; a token Apple says is gone (410,
// or BadDeviceToken on both servers) takes its watch with it.
async function wake(watch, alert) {
  const known = watch.data.apnsEnvironment;
  const order = known ? [known, ...Object.keys(APNS_HOSTS).filter((e) => e !== known)] : Object.keys(APNS_HOSTS);
  for (const environment of order) {
    const { status, reason } = await push(watch.data.deviceToken, environment, alert);
    if (status === 200) {
      if (environment !== known) await watches.doc(watch.id).set({ apnsEnvironment: environment }, { merge: true }).catch(() => {});
      return;
    }
    if (status === 410) { await watches.doc(watch.id).delete().catch(() => {}); return; }
    if (reason !== 'BadDeviceToken') return;
  }
  await watches.doc(watch.id).delete().catch(() => {});
}

// ---- Watching ------------------------------------------------------------

let unseal = async (sealed) => {
  const [result] = await kms.asymmetricDecrypt({ name: KEY_VERSION, ciphertext: Buffer.from(sealed, 'base64') });
  return Buffer.from(result.plaintext).toString('utf8');
};
let makeClient = (options) => new ImapFlow(options);

// The login a watch signs in as. Two records with the same login share
// one connection; anything else (another server, another user) gets its own.
function loginFor(data) {
  const host = String(data.imapHost || ICLOUD_HOST).toLowerCase();
  const port = Number(data.imapPort) || 993;
  const username = String(data.username || data.emailAddress || '');
  return { key: `${host}:${port}|${username.toLowerCase()}`, host, port, username };
}

// Passwords are compared by a keyed hash that lives only in this process,
// so a watch whose password is the one already signed in needs no second
// sign-in to be trusted.
const tagKey = crypto.randomBytes(32);
function passwordTag(password) {
  return crypto.createHmac('sha256', tagKey).update(password).digest();
}

function isVerified(watch) {
  return watch.verifiedSealed === watch.data.sealedPassword;
}

// login key → { login, watches: Map(id → {id, data, verifiedSealed}),
//   client, tag, stopped, attempt, starting, timer, queue }
const accounts = new Map();
// watch id → login key, to find a watch when it's removed or changes login.
const watchLogins = new Map();
// Watches past MAX_WATCHES, adopted as others go.
const waiting = new Map();

function isStale(entry) {
  return entry.stopped || accounts.get(entry.login.key) !== entry;
}

let loginsInFlight = 0;
const loginQueue = [];
async function withLoginSlot(work) {
  if (loginsInFlight >= MAX_CONCURRENT_LOGINS) await new Promise((resolve) => loginQueue.push(resolve));
  loginsInFlight += 1;
  try {
    return await work();
  } finally {
    loginsInFlight -= 1;
    const next = loginQueue.shift();
    if (next) next();
  }
}

function clientFor(entry, password) {
  return makeClient({
    host: entry.login.host, port: entry.login.port, secure: true,
    auth: { user: entry.login.username, pass: password },
    logger: false, maxIdleTime: 20 * 60 * 1000, emitLogs: false,
  });
}

async function connect(entry) {
  if (isStale(entry) || entry.client || entry.starting) return;
  entry.starting = true;
  try {
    // Any of the login's devices' passwords will do; one that the server
    // turns away three times (revoked at account.apple.com) is deleted.
    for (const watch of [...entry.watches.values()]) {
      if (isStale(entry)) return;
      if (!entry.watches.has(watch.id)) continue;
      let password;
      try { password = await withLoginSlot(() => unseal(watch.data.sealedPassword)); } catch { await fail(watch, true); continue; }
      if (isStale(entry)) return;
      const tag = passwordTag(password);
      const client = clientFor(entry, password);
      password = null;
      client.on('error', () => {});
      try {
        await withLoginSlot(() => client.connect());
      } catch (error) {
        client.close();
        await fail(watch, Boolean(error && error.authenticationFailed));
        continue;
      }
      // Removed or replaced while signing in: let go of the connection.
      if (isStale(entry)) { await client.logout().catch(() => {}); return; }
      if (!entry.watches.has(watch.id)) { await client.logout().catch(() => {}); continue; }
      let mailbox;
      try {
        mailbox = await client.mailboxOpen('INBOX', { readOnly: true });
      } catch {
        await client.logout().catch(() => {});
        continue;
      }
      if (isStale(entry)) { await client.logout().catch(() => {}); return; }
      entry.client = client;
      entry.tag = tag;
      entry.attempt = 0;
      verified(watch);
      // The highest message number seen, not the count: a message deleted
      // on another device lowers the count without an EXISTS, so a count
      // check missed the next new mail, and sequence numbers shift.
      let lastUid = Math.max(0, (Number(mailbox.uidNext) || 1) - 1);
      // One EXISTS at a time: two close together would otherwise both
      // fetch from the same lastUid and alert for the same mail twice.
      client.on('exists', () => {
        entry.queue = entry.queue.then(async () => {
          if (entry.client !== client) return;
          // Only the numbers of what arrived: never a header or a body.
          const uids = [];
          try {
            for await (const message of client.fetch(`${lastUid + 1}:*`, { uid: true }, { uid: true })) {
              // "N:*" past the end still returns the last message: skip it.
              if (message.uid > lastUid) uids.push(message.uid);
            }
          } catch { /* wake quietly anyway */ }
          if (uids.length === 0) return;
          lastUid = Math.max(lastUid, ...uids);
          const validity = String(client.mailbox && client.mailbox.uidValidity);
          await notify(entry, uids.slice(-10).map((uid) => `${validity}:${uid}:INBOX`));
        }).catch((e) => log('notify failed', e && e.message));
      });
      client.on('close', () => {
        if (entry.client !== client) return;
        entry.client = null;
        entry.tag = null;
        schedule(entry);
      });
      log('watching', hashed(entry.login.key));
      verifyOthers(entry).catch((e) => log('verify failed', e && e.message));
      return;
    }
    schedule(entry);
  } finally {
    entry.starting = false;
  }
}

function verified(watch) {
  watch.verifiedSealed = watch.data.sealedPassword;
  if (watch.data.failures) watches.doc(watch.id).set({ failures: 0 }, { merge: true }).catch(() => {});
}

// The login's other devices: trusted once their own password is shown to
// work, by matching the one signed in or by signing in once themselves.
async function verifyOthers(entry) {
  if (entry.verifying) { entry.verifyAgain = true; return; }
  entry.verifying = true;
  try {
    do {
      entry.verifyAgain = false;
      for (const watch of [...entry.watches.values()]) {
        if (isStale(entry) || !entry.client) return;
        if (isVerified(watch) || !entry.watches.has(watch.id)) continue;
        const sealed = watch.data.sealedPassword;
        let password;
        try { password = await withLoginSlot(() => unseal(sealed)); } catch { await fail(watch, true); continue; }
        if (entry.tag && crypto.timingSafeEqual(passwordTag(password), entry.tag)) {
          if (watch.data.sealedPassword === sealed) verified(watch);
          continue;
        }
        const check = clientFor(entry, password);
        password = null;
        check.on('error', () => {});
        try {
          await withLoginSlot(() => check.connect());
          await check.logout().catch(() => {});
          if (watch.data.sealedPassword === sealed) verified(watch);
        } catch (error) {
          check.close();
          await fail(watch, Boolean(error && error.authenticationFailed));
        }
      }
    } while (entry.verifyAgain);
  } finally {
    entry.verifying = false;
  }
}

async function fail(watch, authentication) {
  if (!authentication) return;
  const failures = (watch.data.failures || 0) + 1;
  watch.data = { ...watch.data, failures };
  if (failures >= 3) {
    await watches.doc(watch.id).delete().catch(() => {});
    log('removed a watch the server keeps turning away');
    return;
  }
  await watches.doc(watch.id).set({ failures }, { merge: true }).catch(() => {});
}

function connectSoon(entry) {
  clearTimeout(entry.timer);
  entry.timer = null;
  connect(entry).catch((e) => { log('connect failed', e && e.message); schedule(entry); });
}

function schedule(entry) {
  if (isStale(entry) || entry.watches.size === 0) return;
  clearTimeout(entry.timer);
  entry.attempt = Math.min(entry.attempt + 1, 8);
  const delay = Math.min(5 * 2 ** entry.attempt, 600) * 1000;
  entry.timer = setTimeout(() => connectSoon(entry), delay);
}

// Only the devices whose own password signed in to this login.
function notifyTargets(entry) {
  return [...entry.watches.values()].filter(isVerified);
}

async function notify(entry, messageIds) {
  const results = await Promise.allSettled(notifyTargets(entry).map(async (watch) => {
    if (watch.data.alerts) {
      for (const messageId of messageIds) await wake(watch, { emailAddress: watch.data.emailAddress, messageId });
    }
    await wake(watch);
  }));
  const failed = results.filter((r) => r.status === 'rejected').length;
  if (failed) log(`${failed} wake-ups failed`);
}

async function stop(entry) {
  entry.stopped = true;
  clearTimeout(entry.timer);
  if (accounts.get(entry.login.key) === entry) accounts.delete(entry.login.key);
  const client = entry.client;
  entry.client = null;
  if (client) await client.logout().catch(() => {});
}

function hashed(value) {
  return crypto.createHash('sha256').update(value).digest('hex').slice(0, 10);
}

function removeWatch(id) {
  waiting.delete(id);
  const key = watchLogins.get(id);
  if (!key) return;
  watchLogins.delete(id);
  const entry = accounts.get(key);
  if (!entry) return;
  entry.watches.delete(id);
  if (entry.watches.size === 0) stop(entry).catch(() => {});
}

// A watch added or changed. Its own `failures` count or alert switch
// changing keeps the connection as it is; a new password or login tries
// again right away (an unchanged one waits for the backoff, so a server
// that turns it away isn't asked again and again).
function upsertWatch(id, data) {
  const login = loginFor(data);
  const previousKey = watchLogins.get(id);
  if (previousKey && previousKey !== login.key) removeWatch(id);
  if (!watchLogins.has(id) && watchLogins.size >= MAX_WATCHES) {
    if (!waiting.has(id)) log('watch limit reached');
    waiting.set(id, data);
    return;
  }
  waiting.delete(id);
  let entry = accounts.get(login.key);
  if (!entry) {
    entry = { login, watches: new Map(), client: null, tag: null, stopped: false, attempt: 0, starting: false,
      timer: null, queue: Promise.resolve(), verifying: false, verifyAgain: false };
    accounts.set(login.key, entry);
  }
  watchLogins.set(id, login.key);
  const existing = entry.watches.get(id);
  if (existing) {
    const newPassword = existing.data.sealedPassword !== data.sealedPassword;
    existing.data = data;
    if (!newPassword) return;
    if (entry.client) verifyOthers(entry).catch(() => {});
    else connectSoon(entry);
    return;
  }
  entry.watches.set(id, { id, data, verifiedSealed: null });
  if (entry.client) verifyOthers(entry).catch(() => {});
  else connectSoon(entry);
}

function adoptWaiting() {
  for (const [id, data] of waiting) {
    if (watchLogins.size >= MAX_WATCHES) return;
    upsertWatch(id, data);
  }
}

function start() {
  // Every watch, live: a new one starts watching within seconds, a deleted
  // one (switch off, account removed) stops.
  watches.onSnapshot((snapshot) => {
    for (const change of snapshot.docChanges()) {
      if (change.type === 'removed') {
        removeWatch(change.doc.id);
        continue;
      }
      upsertWatch(change.doc.id, change.doc.data());
    }
    adoptWaiting();
  }, (error) => { log('watch list error', error.message); process.exit(1); });

  // One account's trouble must never stop the others' watches.
  process.on('unhandledRejection', (error) => log('unhandled', error && error.message));
  process.on('uncaughtException', (error) => log('uncaught', error && error.message));

  // Cloud Run needs a port to call the service healthy.
  http.createServer((req, res) => {
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.end(`watching ${[...accounts.values()].filter((a) => a.client).length} of ${accounts.size}`);
  }).listen(process.env.PORT || 8080);
}

if (require.main === module) start();

// For tests: the pure parts, and seams for the IMAP client and unsealing.
module.exports = {
  loginFor, notifyTargets, upsertWatch, removeWatch, accounts, watchLogins, waiting,
  _setSeams(seams) {
    if (seams.unseal) unseal = seams.unseal;
    if (seams.makeClient) makeClient = seams.makeClient;
  },
};
