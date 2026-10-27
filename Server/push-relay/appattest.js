// App Attest verification: proof that a call comes from a genuine copy of
// Corres on real Apple hardware, not just something shaped like it. Pure
// checks only, no Firestore, so they can be tested on their own. The steps
// follow Apple's "Validating apps that connect to your server":
// https://developer.apple.com/documentation/devicecheck/validating-apps-that-connect-to-your-server
const crypto = require('crypto');
const cbor = require('cbor');

// Apple App Attestation Root CA, from
// https://www.apple.com/certificateauthority/Apple_App_Attestation_Root_CA.pem
// (valid to 2045; SHA-256 fingerprint 1C:B9:82:3B:...:62:42:C9:32).
const APPLE_ROOT_PEM = `-----BEGIN CERTIFICATE-----
MIICITCCAaegAwIBAgIQC/O+DvHN0uD7jG5yH2IXmDAKBggqhkjOPQQDAzBSMSYw
JAYDVQQDDB1BcHBsZSBBcHAgQXR0ZXN0YXRpb24gUm9vdCBDQTETMBEGA1UECgwK
QXBwbGUgSW5jLjETMBEGA1UECAwKQ2FsaWZvcm5pYTAeFw0yMDAzMTgxODMyNTNa
Fw00NTAzMTUwMDAwMDBaMFIxJjAkBgNVBAMMHUFwcGxlIEFwcCBBdHRlc3RhdGlv
biBSb290IENBMRMwEQYDVQQKDApBcHBsZSBJbmMuMRMwEQYDVQQIDApDYWxpZm9y
bmlhMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAERTHhmLW07ATaFQIEVwTtT4dyctdh
NbJhFs/Ii2FdCgAHGbpphY3+d8qjuDngIN3WVhQUBHAoMeQ/cLiP1sOUtgjqK9au
Yen1mMEvRq9Sk3Jm5X8U62H+xTD3FE9TgS41o0IwQDAPBgNVHRMBAf8EBTADAQH/
MB0GA1UdDgQWBBSskRBTM72+aEH/pwyp5frq5eWKoTAOBgNVHQ8BAf8EBAMCAQYw
CgYIKoZIzj0EAwMDaAAwZQIwQgFGnByvsiVbpTKwSga0kP0e8EeDS4+sQmTvb7vn
53O5+FRXgeLhpJ06ysC5PrOyAjEAp5U4xDgEgllF7En3VcE3iexZZtKeYnpqtijV
oyFraWVIyd/dganmrduC1bmTBGwD
-----END CERTIFICATE-----`;

// Team ID + "." + bundle identifier. The iPhone, iPad and Mac apps share
// one App ID; the Mac's debug build ("Corres Debug") has its own.
const APP_IDS = ['7GGTC43CG8.studio.anwarcreative.corres', '7GGTC43CG8.studio.anwarcreative.corres.debug'];

const NONCE_OID = '1.2.840.113635.100.8.2';
// macOS only: the key's access policy, which must say SIP and full
// security are on. Apple gives this exact value and says it never changes.
const MAC_ACL_OID = '1.2.840.113635.100.8.6';
const MAC_ACL = 'MEAMAjExMDowCQwCb2uhAwEB/zAJDAJvYaEDAQH/MAsMBG9kZWyhAwEB/zAVDARvc2duoAYMBHJzZWMwBaYDAgEB';

// "appattest" plus seven zero bytes for production keys (TestFlight, App
// Store, or the production entitlement); "appattestdevelop" for keys made
// by a development build without it.
const AAGUIDS = {
  production: Buffer.concat([Buffer.from('appattest'), Buffer.alloc(7)]),
  development: Buffer.from('appattestdevelop'),
};

class AttestError extends Error {
  constructor(reason) {
    super(reason);
    this.reason = reason;
  }
}

function sha256(...parts) {
  const h = crypto.createHash('sha256');
  for (const part of parts) h.update(part);
  return h.digest();
}

// CBOR maps decode to a Map or a plain object depending on their keys.
function field(value, key) {
  if (value instanceof Map) return value.get(key);
  return value && typeof value === 'object' ? value[key] : undefined;
}

function bytes(value) {
  return (value instanceof Uint8Array) ? Buffer.from(value) : null;
}

// A minimal DER reader: just enough to find one extension in a
// certificate. Node's X509Certificate doesn't expose custom extensions.
function readTLV(buf, offset) {
  if (offset + 2 > buf.length) throw new AttestError('bad-certificate');
  const tag = buf[offset];
  let length = buf[offset + 1];
  let start = offset + 2;
  if (length & 0x80) {
    const count = length & 0x7f;
    if (count < 1 || count > 4 || start + count > buf.length) throw new AttestError('bad-certificate');
    length = 0;
    for (let i = 0; i < count; i++) length = length * 256 + buf[start + i];
    start += count;
  }
  const end = start + length;
  if (end > buf.length) throw new AttestError('bad-certificate');
  return { tag, start, end };
}

function children(buf, tlv) {
  const out = [];
  for (let offset = tlv.start; offset < tlv.end;) {
    const child = readTLV(buf, offset);
    out.push(child);
    offset = child.end;
  }
  return out;
}

function oidString(der) {
  const parts = [Math.floor(der[0] / 40), der[0] % 40];
  let value = 0;
  for (const byte of der.subarray(1)) {
    value = value * 128 + (byte & 0x7f);
    if (!(byte & 0x80)) { parts.push(value); value = 0; }
  }
  return parts.join('.');
}

// The extnValue (inside its OCTET STRING) of the extension with this OID,
// or null if the certificate doesn't have it.
function certExtension(der, oid) {
  const tbs = children(der, readTLV(der, 0))[0];
  const tagged = children(der, tbs).find((c) => c.tag === 0xa3);
  if (!tagged) return null;
  for (const extension of children(der, children(der, tagged)[0])) {
    const parts = children(der, extension);
    if (parts[0].tag === 0x06 && oidString(der.subarray(parts[0].start, parts[0].end)) === oid) {
      const value = parts[parts.length - 1];
      return der.subarray(value.start, value.end);
    }
  }
  return null;
}

// Both Apple extensions are a sequence holding a single OCTET STRING
// (the nonce one inside an explicit [1] tag): the first one found.
function innerOctetString(buf) {
  const walk = (tlv) => {
    if (tlv.tag === 0x04) return buf.subarray(tlv.start, tlv.end);
    if (tlv.tag & 0x20) {
      for (const child of children(buf, tlv)) {
        const found = walk(child);
        if (found) return found;
      }
    }
    return null;
  };
  return walk(readTLV(buf, 0));
}

// WebAuthn authenticator data: RP ID hash (32), flags (1), counter (4),
// then for an attestation the aaguid (16), credential id length (2) and
// id, the public key as COSE, and optional extensions.
function parseAuthData(authData) {
  if (authData.length < 37) throw new AttestError('bad-auth-data');
  const parsed = {
    rpIdHash: authData.subarray(0, 32),
    flags: authData[32],
    counter: authData.readUInt32BE(33),
  };
  if (parsed.flags & 0x40) {
    if (authData.length < 55) throw new AttestError('bad-auth-data');
    parsed.aaguid = authData.subarray(37, 53);
    const idLength = authData.readUInt16BE(53);
    if (authData.length < 55 + idLength) throw new AttestError('bad-auth-data');
    parsed.credentialId = authData.subarray(55, 55 + idLength);
    if (parsed.flags & 0x80) {
      // Only read, never required: the launch category and app version.
      try {
        const [, extensions] = cbor.decodeAllSync(authData.subarray(55 + idLength));
        parsed.validationCategory = field(extensions, 'apple_validation_category_01');
        parsed.bundleVersion = field(extensions, 'apple_bundle_version_01');
      } catch { /* not needed to trust the key */ }
    }
  }
  return parsed;
}

function appIdFor(rpIdHash, appIds) {
  return appIds.find((appId) => sha256(appId).equals(rpIdHash)) || null;
}

// Checks an attestation for the key `keyId` (32 raw bytes), made over the
// one-time `challenge` this server handed out. Returns what to keep for
// later assertions; throws AttestError with a short reason otherwise.
// `platform` is what the app says it runs on: "macOS" for a Mac (or the
// iPad app on a Mac), anything else or nothing for an iPhone or iPad.
function verifyAttestation({ attestation, keyId, challenge, appIds = APP_IDS, rootPem = APPLE_ROOT_PEM,
  now = new Date(), allowDevelopment = true, platform = null }) {
  let decoded;
  try {
    decoded = cbor.decodeFirstSync(attestation);
  } catch {
    throw new AttestError('bad-cbor');
  }
  if (field(decoded, 'fmt') !== 'apple-appattest') throw new AttestError('bad-format');
  const statement = field(decoded, 'attStmt');
  const authData = bytes(field(decoded, 'authData'));
  const x5c = field(statement, 'x5c');
  if (!authData || !Array.isArray(x5c) || x5c.length < 2) throw new AttestError('bad-format');

  // 1. The leaf and intermediate chain up to Apple's root, all in date.
  let leaf;
  let intermediate;
  let root;
  try {
    leaf = new crypto.X509Certificate(bytes(x5c[0]));
    intermediate = new crypto.X509Certificate(bytes(x5c[1]));
    root = new crypto.X509Certificate(rootPem);
  } catch {
    throw new AttestError('bad-certificate');
  }
  const inDate = (cert) => new Date(cert.validFrom) <= now && now <= new Date(cert.validTo);
  if (!intermediate.ca || !intermediate.checkIssued(root) || !intermediate.verify(root.publicKey)
      || !leaf.checkIssued(intermediate) || !leaf.verify(intermediate.publicKey)
      || ![leaf, intermediate, root].every(inDate)) {
    throw new AttestError('untrusted-chain');
  }

  // 2-4. nonce = SHA256(authData || SHA256(challenge)), as the leaf says.
  const nonce = sha256(authData, sha256(challenge));
  const nonceExtension = certExtension(leaf.raw, NONCE_OID);
  const certNonce = nonceExtension && innerOctetString(nonceExtension);
  if (!certNonce || !certNonce.equals(nonce)) throw new AttestError('nonce-mismatch');

  // The key's access policy (OID ...100.8.6). Apple defines the check for
  // macOS keys only: SIP and full security on, this exact value. iPhone and
  // iPad keys carry the extension too, with a policy of their own, so
  // checking it on every key refused every iPhone (all /attest calls from
  // builds 35 to 39 were "mac-policy"). It's checked for keys the app says
  // come from a Mac (the Mac app, or the iPad app running on one); the
  // value is kept either way, so the ones iPhones send can be seen.
  const acl = certExtension(leaf.raw, MAC_ACL_OID);
  const aclValue = acl && innerOctetString(acl);
  const aclMatchesMac = Boolean(aclValue)
    && (aclValue.toString('base64') === MAC_ACL || aclValue.toString('latin1') === MAC_ACL);
  if (platform === 'macOS' && !aclMatchesMac) throw new AttestError('mac-policy');

  // 5. The key id is the SHA256 of the public key (uncompressed point).
  const jwk = leaf.publicKey.export({ format: 'jwk' });
  if (jwk.kty !== 'EC' || jwk.crv !== 'P-256') throw new AttestError('bad-key');
  const point = Buffer.concat([Buffer.from([4]), Buffer.from(jwk.x, 'base64url'), Buffer.from(jwk.y, 'base64url')]);
  if (!sha256(point).equals(keyId)) throw new AttestError('key-id-mismatch');

  // 6-9. Our App ID, a fresh counter, a known environment, the same key.
  const parsed = parseAuthData(authData);
  const appId = appIdFor(parsed.rpIdHash, appIds);
  if (!appId) throw new AttestError('wrong-app');
  if (parsed.counter !== 0) throw new AttestError('counter-not-zero');
  const environment = Object.keys(AAGUIDS).find((name) => parsed.aaguid && AAGUIDS[name].equals(parsed.aaguid));
  if (!environment) throw new AttestError('bad-aaguid');
  if (environment === 'development' && !allowDevelopment) throw new AttestError('development-key');
  if (!parsed.credentialId || !parsed.credentialId.equals(keyId)) throw new AttestError('credential-mismatch');

  return {
    publicKeyPem: leaf.publicKey.export({ type: 'spki', format: 'pem' }),
    appId,
    environment,
    receipt: bytes(field(statement, 'receipt')),
    validationCategory: parsed.validationCategory,
    bundleVersion: parsed.bundleVersion,
    accessPolicy: aclValue ? (aclMatchesMac ? 'macos-full-security' : crypto.createHash('sha256').update(aclValue).digest('hex').slice(0, 16)) : null,
  };
}

// Checks an assertion over `clientData` (the exact request body) with the
// stored key. Returns the new counter to store; throws AttestError otherwise.
function verifyAssertion({ assertion, clientData, publicKeyPem, appId, previousCounter }) {
  let decoded;
  try {
    decoded = cbor.decodeFirstSync(assertion);
  } catch {
    throw new AttestError('bad-cbor');
  }
  const signature = bytes(field(decoded, 'signature'));
  const authData = bytes(field(decoded, 'authenticatorData'));
  if (!signature || !authData) throw new AttestError('bad-format');
  const nonce = sha256(authData, sha256(clientData));
  let valid = false;
  try {
    valid = crypto.verify('sha256', nonce, publicKeyPem, signature);
  } catch {
    valid = false;
  }
  if (!valid) throw new AttestError('bad-signature');
  const parsed = parseAuthData(authData);
  if (!sha256(appId).equals(parsed.rpIdHash)) throw new AttestError('wrong-app');
  // Strictly increasing: a replayed assertion has an old counter.
  if (!(parsed.counter > previousCounter)) throw new AttestError('replayed-counter');
  return { counter: parsed.counter };
}

module.exports = { verifyAttestation, verifyAssertion, AttestError, APP_IDS, APPLE_ROOT_PEM };
