// DeviceCheck: the Mac's proof that a call comes from Corres. Macs can't
// use App Attest (DCAppAttestService.isSupported is false on Macs before
// macOS 27, and the Mac app doesn't carry the App Attest entitlement), so
// the Mac app sends a DeviceCheck token instead
// (DCDevice.generateToken, macOS 10.15 and later), and this asks Apple
// whether it's real. A valid token says the call comes from a genuine
// Apple device running an app signed by our team. It's weaker than App
// Attest: it isn't tied to the request, so each token is taken only once.
// No Firestore here, so it can be tested on its own; index.js passes in
// what remembers used tokens. Apple's server side:
// https://developer.apple.com/documentation/devicecheck/accessing-and-modifying-per-device-data
const crypto = require('crypto');

const HOSTS = {
  production: 'https://api.devicecheck.apple.com',
  development: 'https://api.development.devicecheck.apple.com',
};

// Base64 of Apple's encrypted device information, no line breaks. Real
// tokens are a few thousand characters.
const TOKEN_PATTERN = /^[A-Za-z0-9+/]{40,16384}={0,2}$/;
const APPLE_TIMEOUT_MS = 5_000;
// Apple keeps a token good long enough to retry one request; a used one
// is remembered a day, which is well past that.
const USED_TOKEN_LIFETIME_MS = 24 * 60 * 60_000;

function base64url(input) {
  return Buffer.from(input).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

// The same ES256 provider token APNs takes (Apple says to build it the
// same way): kid is the key's id, iss the team, iat now. Cached just under
// Apple's one-hour limit.
const TOKEN_LIFETIME_MS = 50 * 60_000;
let cached = null;

function authorizationToken({ keyId, teamId, privateKey, now = Date.now() }) {
  if (cached && cached.keyId === keyId && cached.teamId === teamId && now - cached.issuedAt < TOKEN_LIFETIME_MS) {
    return cached.token;
  }
  const header = base64url(JSON.stringify({ alg: 'ES256', kid: keyId }));
  const payload = base64url(JSON.stringify({ iss: teamId, iat: Math.floor(now / 1000) }));
  const signingInput = `${header}.${payload}`;
  const signature = crypto.sign('sha256', Buffer.from(signingInput),
    { key: crypto.createPrivateKey(privateKey), dsaEncoding: 'ieee-p1363' });
  const token = `${signingInput}.${base64url(signature)}`;
  cached = { keyId, teamId, issuedAt: now, token };
  return token;
}

// The key settings, or null when DeviceCheck isn't set up on this relay.
function configFrom(env) {
  const keyId = env.DEVICECHECK_KEY_ID;
  const teamId = env.DEVICECHECK_TEAM_ID || env.APNS_TEAM_ID;
  // The APNs key can do DeviceCheck too once it's enabled on that key in
  // the developer portal; then the same key id and secret are used.
  const privateKey = env.DEVICECHECK_KEY || (keyId && keyId === env.APNS_KEY_ID ? env.APNS_AUTH_KEY : null);
  if (!keyId || !teamId || !privateKey) return null;
  return { keyId, teamId, privateKey, allowDevelopment: env.DEVICECHECK_DEVELOPMENT !== '0' };
}

// One validate_device_token call. Returns Apple's status (0 for no answer).
async function askApple({ token, environment, config, hosts, fetchImpl }) {
  try {
    const response = await fetchImpl(`${hosts[environment]}/v1/validate_device_token`, {
      method: 'POST',
      headers: {
        authorization: `Bearer ${authorizationToken(config)}`,
        'content-type': 'application/json',
      },
      body: JSON.stringify({
        device_token: token,
        transaction_id: crypto.randomUUID(),
        timestamp: Date.now(),
      }),
      signal: AbortSignal.timeout(APPLE_TIMEOUT_MS),
    });
    // Drained so the connection can be reused; Apple's text isn't needed.
    await response.text().catch(() => '');
    return response.status;
  } catch {
    return 0;
  }
}

// Whether `token` (the Corres-Device-Check header) is a DeviceCheck token
// Apple vouches for and that hasn't been used before. Never throws; says
// why when it isn't. Production first; a 400 there means the token may
// come from a build run from Xcode, which Apple checks on its development
// server. `markUsed(hash, expiresAt)` resolves true the first time it sees
// a hash and false after that.
async function checkDeviceToken({ token, config, markUsed, hosts = HOSTS, fetchImpl = fetch }) {
  if (token === undefined || token === null || token === '') return { deviceChecked: false, reason: 'none' };
  if (!config) return { deviceChecked: false, reason: 'not-configured' };
  if (typeof token !== 'string' || !TOKEN_PATTERN.test(token)) return { deviceChecked: false, reason: 'malformed' };
  const environments = config.allowDevelopment ? ['production', 'development'] : ['production'];
  let environment = null;
  let status = 0;
  for (const candidate of environments) {
    status = await askApple({ token, environment: candidate, config, hosts, fetchImpl });
    if (status === 200) { environment = candidate; break; }
    if (status !== 400) break;
  }
  if (!environment) {
    // 400: Apple doesn't know the token. 401 or 403: the key itself is
    // wrong (not enabled for DeviceCheck, wrong id or team), worth fixing.
    // Anything else is Apple being busy or down.
    const reason = status === 400 ? 'invalid-token'
      : (status === 401 || status === 403) ? 'apple-auth'
        : 'apple-unavailable';
    return { deviceChecked: false, reason, status };
  }
  const tokenHash = crypto.createHash('sha256').update(token).digest('hex');
  let fresh = false;
  try {
    fresh = await markUsed(tokenHash, Date.now() + USED_TOKEN_LIFETIME_MS);
  } catch {
    return { deviceChecked: false, reason: 'error', environment };
  }
  if (!fresh) return { deviceChecked: false, reason: 'replayed-token', environment };
  return { deviceChecked: true, reason: null, environment };
}

module.exports = { checkDeviceToken, configFrom, authorizationToken, HOSTS, TOKEN_PATTERN };
