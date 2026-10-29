// Proof that whoever registers an address signed in to it: the OpenID
// Connect ID token the app's own sign-in already gets (Google for Gmail,
// Microsoft for Outlook), checked here and never kept. Without it anyone
// could register someone else's address with their own device and learn
// when that person gets mail.
//
// Checked: the signature against the provider's published keys (RS256
// only), the audience (Corres's own client ids), the issuer, the expiry,
// and that the token names the address being registered (for Google, an
// address Google has verified). Nothing from the token is logged or stored.
const crypto = require('crypto');

const PROVIDERS = {
  google: { keysURL: 'https://www.googleapis.com/oauth2/v3/certs' },
  microsoft: { keysURL: 'https://login.microsoftonline.com/common/discovery/v2.0/keys' },
};
const GOOGLE_ISSUERS = new Set(['https://accounts.google.com', 'accounts.google.com']);
// Work and school accounts are issued by their own tenant; personal
// accounts by 9188040d-6c67-4c5b-b112-36a304b66dad. Either way the tenant
// in the issuer is the token's own `tid`.
const MICROSOFT_ISSUER = /^https:\/\/login\.microsoftonline\.com\/([0-9a-f-]{36})\/v2\.0$/;
const TOKEN_PATTERN = /^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/;
const MAX_TOKEN_LENGTH = 8192;
// Clocks differ a little between the phone, the provider and here.
const SKEW_MS = 2 * 60_000;
// Keys are kept for as long as the provider's Cache-Control says (at most
// a day), and fetched again early, at most every five minutes, when a
// token names a key that isn't known yet (the provider rotated).
const DEFAULT_KEYS_MAX_AGE_MS = 6 * 60 * 60_000;
const LONGEST_KEYS_MAX_AGE_MS = 24 * 60 * 60_000;
const EARLY_REFRESH_MS = 5 * 60_000;
const FETCH_TIMEOUT_MS = 3000;

class ProofError extends Error {
  constructor(reason) {
    super(reason);
    this.reason = reason;
  }
}

const keySets = {}; // provider → { at, maxAgeMs, keys: Map(kid → KeyObject) }
const fetching = {}; // provider → Promise

function maxAgeOf(cacheControl) {
  const match = /max-age=(\d+)/i.exec(cacheControl || '');
  return match ? Math.min(Number(match[1]) * 1000, LONGEST_KEYS_MAX_AGE_MS) : DEFAULT_KEYS_MAX_AGE_MS;
}

async function fetchKeys(provider, fetchImpl) {
  if (fetching[provider]) return fetching[provider];
  fetching[provider] = (async () => {
    let response;
    try {
      response = await fetchImpl(PROVIDERS[provider].keysURL, { signal: AbortSignal.timeout(FETCH_TIMEOUT_MS) });
    } catch {
      throw new ProofError('keys-unavailable');
    }
    if (!response.ok) throw new ProofError('keys-unavailable');
    const body = await response.json().catch(() => null);
    const keys = new Map();
    for (const jwk of (body && Array.isArray(body.keys)) ? body.keys : []) {
      if (!jwk || jwk.kty !== 'RSA' || typeof jwk.kid !== 'string' || (jwk.use && jwk.use !== 'sig')) continue;
      try {
        keys.set(jwk.kid, crypto.createPublicKey({ key: { kty: 'RSA', n: jwk.n, e: jwk.e }, format: 'jwk' }));
      } catch { /* a key Node can't read is skipped */ }
    }
    const set = { at: Date.now(), maxAgeMs: maxAgeOf(response.headers && response.headers.get('cache-control')), keys };
    keySets[provider] = set;
    return set;
  })().finally(() => { delete fetching[provider]; });
  return fetching[provider];
}

async function signingKey(provider, kid, fetchImpl) {
  let set = keySets[provider];
  if (!set || Date.now() - set.at > set.maxAgeMs) set = await fetchKeys(provider, fetchImpl);
  if (!set.keys.has(kid) && Date.now() - set.at > EARLY_REFRESH_MS) set = await fetchKeys(provider, fetchImpl);
  const key = set.keys.get(kid);
  if (!key) throw new ProofError('unknown-signing-key');
  return key;
}

function decode(token) {
  if (typeof token !== 'string' || token.length > MAX_TOKEN_LENGTH || !TOKEN_PATTERN.test(token)) {
    throw new ProofError('malformed');
  }
  const [header, payload, signature] = token.split('.');
  try {
    return {
      header: JSON.parse(Buffer.from(header, 'base64url').toString('utf8')),
      claims: JSON.parse(Buffer.from(payload, 'base64url').toString('utf8')),
      signature: Buffer.from(signature, 'base64url'),
      signed: Buffer.from(`${header}.${payload}`),
    };
  } catch {
    throw new ProofError('malformed');
  }
}

function lower(value) {
  return typeof value === 'string' ? value.trim().toLowerCase() : null;
}

function checkClaims(provider, claims, { address, audiences, now }) {
  if (!claims || typeof claims !== 'object') throw new ProofError('malformed');
  const audience = Array.isArray(claims.aud) ? claims.aud : [claims.aud];
  if (!audience.some((aud) => audiences.includes(aud))) throw new ProofError('wrong-audience');
  if (typeof claims.exp !== 'number' || claims.exp * 1000 < now - SKEW_MS) throw new ProofError('expired');
  if (typeof claims.nbf === 'number' && claims.nbf * 1000 > now + SKEW_MS) throw new ProofError('not-yet-valid');
  if (typeof claims.iat === 'number' && claims.iat * 1000 > now + SKEW_MS) throw new ProofError('not-yet-valid');
  const wanted = lower(address);
  if (provider === 'google') {
    if (!GOOGLE_ISSUERS.has(claims.iss)) throw new ProofError('wrong-issuer');
    if (!(claims.email_verified === true || claims.email_verified === 'true')) throw new ProofError('unverified-address');
    if (lower(claims.email) !== wanted) throw new ProofError('wrong-address');
    return;
  }
  const issuer = MICROSOFT_ISSUER.exec(typeof claims.iss === 'string' ? claims.iss : '');
  if (!issuer || issuer[1] !== claims.tid) throw new ProofError('wrong-issuer');
  // Corres names an Outlook account by Graph's `mail`, or the user
  // principal name when there's none (MicrosoftSignIn); the token carries
  // those as `email` and `preferred_username`.
  const names = [claims.email, claims.preferred_username, claims.upn].map(lower).filter(Boolean);
  if (!names.includes(wanted)) throw new ProofError('wrong-address');
}

// { verified, reason } for one token; never throws. `provider` is
// "google" or "microsoft"; `audiences` the client ids the token may be for.
async function check({ provider, token, address, audiences, now = Date.now(), fetchImpl = globalThis.fetch }) {
  if (!token) return { verified: false, reason: 'none' };
  if (!PROVIDERS[provider]) return { verified: false, reason: 'unsupported' };
  try {
    const { header, claims, signature, signed } = decode(token);
    if (!header || header.alg !== 'RS256' || typeof header.kid !== 'string') throw new ProofError('malformed');
    const key = await signingKey(provider, header.kid, fetchImpl);
    if (!crypto.verify('sha256', signed, key, signature)) throw new ProofError('bad-signature');
    checkClaims(provider, claims, { address, audiences, now });
    return { verified: true, reason: null };
  } catch (error) {
    return { verified: false, reason: error instanceof ProofError ? error.reason : 'error' };
  }
}

module.exports = { check, ProofError, _keySets: keySets };
