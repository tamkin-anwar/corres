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

function push(deviceToken, environment, alert) {
  return new Promise((resolve) => {
    const client = http2.connect(`https://${APNS_HOSTS[environment]}`);
    client.on('error', () => resolve({ status: 0 }));
    const headers = alert
      ? { 'apns-push-type': 'alert', 'apns-priority': '10',
          'apns-collapse-id': crypto.createHash('sha256').update(alert.messageId).digest('hex').slice(0, 64) }
      : { 'apns-push-type': 'background', 'apns-priority': '5' };
    const request = client.request({
      ':method': 'POST', ':path': `/3/device/${deviceToken}`,
      authorization: `bearer ${apnsToken()}`, 'apns-topic': process.env.APNS_BUNDLE_ID, ...headers,
    });
    let status = 0;
    let body = '';
    request.setEncoding('utf8');
    request.on('response', (h) => { status = h[':status']; });
    request.on('data', (c) => { body += c; });
    request.on('end', () => {
      client.close();
      let reason = null;
      try { reason = body ? JSON.parse(body).reason : null; } catch { reason = null; }
      resolve({ status, reason });
    });
    request.write(JSON.stringify(alert
      ? { aps: { alert: { title: 'New email', body: alert.emailAddress }, sound: 'default', 'mutable-content': 1 },
          account: alert.emailAddress, message: alert.messageId }
      : { aps: { 'content-available': 1 } }));
    request.end();
  });
}

// Through the device's own APNs server; a token Apple says is gone takes
// its watch with it.
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
}

// ---- Watching ------------------------------------------------------------

async function unseal(sealed) {
  const [result] = await kms.asymmetricDecrypt({ name: KEY_VERSION, ciphertext: Buffer.from(sealed, 'base64') });
  return Buffer.from(result.plaintext).toString('utf8');
}

// address → { watches: Map(id → {id, data}), client, stopped, attempt }
const accounts = new Map();

function account(emailAddress) {
  if (!accounts.has(emailAddress)) accounts.set(emailAddress, { watches: new Map(), client: null, stopped: false, attempt: 0, starting: false });
  return accounts.get(emailAddress);
}

async function connect(emailAddress) {
  const entry = accounts.get(emailAddress);
  if (!entry || entry.stopped || entry.client || entry.starting) return;
  entry.starting = true;
  try {
    // Any of the account's devices' passwords will do; one that iCloud
    // turns away three times (revoked at account.apple.com) is deleted.
    for (const watch of [...entry.watches.values()]) {
      let password;
      try { password = await unseal(watch.data.sealedPassword); } catch { await fail(watch, true); continue; }
      const client = new ImapFlow({
        host: 'imap.mail.me.com', port: 993, secure: true,
        auth: { user: emailAddress, pass: password },
        logger: false, maxIdleTime: 20 * 60 * 1000, emitLogs: false,
      });
      password = null;
      try {
        await client.connect();
      } catch (error) {
        await fail(watch, Boolean(error && error.authenticationFailed));
        continue;
      }
      if (watch.data.failures) await watches.doc(watch.id).set({ failures: 0 }, { merge: true }).catch(() => {});
      const mailbox = await client.mailboxOpen('INBOX', { readOnly: true });
      entry.client = client;
      entry.attempt = 0;
      let count = mailbox.exists;
      client.on('exists', async (data) => {
        if (data.count <= count) { count = data.count; return; }
        const from = count + 1;
        count = data.count;
        // Only the numbers of what arrived: never a header or a body.
        const uids = [];
        try {
          for await (const message of client.fetch(`${from}:*`, { uid: true })) uids.push(message.uid);
        } catch { /* wake quietly anyway */ }
        const validity = String(client.mailbox && client.mailbox.uidValidity);
        await notify(emailAddress, uids.slice(-10).map((uid) => `${validity}:${uid}:INBOX`));
      });
      client.on('close', () => { if (entry.client === client) { entry.client = null; schedule(emailAddress); } });
      client.on('error', () => {});
      log('watching', hashed(emailAddress));
      return;
    }
    schedule(emailAddress);
  } finally {
    entry.starting = false;
  }
}

async function fail(watch, authentication) {
  const failures = (watch.data.failures || 0) + (authentication ? 1 : 0);
  if (authentication && failures >= 3) {
    await watches.doc(watch.id).delete().catch(() => {});
    log('removed a watch iCloud keeps turning away');
    return;
  }
  if (authentication) await watches.doc(watch.id).set({ failures }, { merge: true }).catch(() => {});
}

function schedule(emailAddress) {
  const entry = accounts.get(emailAddress);
  if (!entry || entry.stopped || entry.watches.size === 0) return;
  entry.attempt = Math.min(entry.attempt + 1, 8);
  const delay = Math.min(5 * 2 ** entry.attempt, 600) * 1000;
  setTimeout(() => connect(emailAddress), delay);
}

async function notify(emailAddress, messageIds) {
  const entry = accounts.get(emailAddress);
  if (!entry) return;
  await Promise.all([...entry.watches.values()].map(async (watch) => {
    if (watch.data.alerts) for (const messageId of messageIds) await wake(watch, { emailAddress, messageId });
    await wake(watch);
  }));
}

async function stop(emailAddress) {
  const entry = accounts.get(emailAddress);
  if (!entry) return;
  entry.stopped = true;
  accounts.delete(emailAddress);
  if (entry.client) await entry.client.logout().catch(() => {});
}

function hashed(value) {
  return crypto.createHash('sha256').update(value).digest('hex').slice(0, 10);
}

// Every watch, live: a new one starts watching within seconds, a deleted
// one (switch off, account removed) stops.
watches.onSnapshot((snapshot) => {
  for (const change of snapshot.docChanges()) {
    const data = change.doc.data();
    const emailAddress = data.emailAddress;
    if (change.type === 'removed') {
      const entry = accounts.get(emailAddress);
      if (!entry) continue;
      entry.watches.delete(change.doc.id);
      if (entry.watches.size === 0) stop(emailAddress);
      continue;
    }
    const entry = account(emailAddress);
    const before = entry.watches.get(change.doc.id);
    entry.watches.set(change.doc.id, { id: change.doc.id, data });
    // A new password (re-registered after a change) is tried right away.
    if (!entry.client || (before && before.data.sealedPassword !== data.sealedPassword && !entry.client)) connect(emailAddress);
  }
}, (error) => { log('watch list error', error.message); process.exit(1); });

// Cloud Run needs a port to call the service healthy.
http.createServer((req, res) => {
  res.writeHead(200, { 'Content-Type': 'text/plain' });
  res.end(`watching ${[...accounts.values()].filter((a) => a.client).length} of ${accounts.size}`);
}).listen(process.env.PORT || 8080);
