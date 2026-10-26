// Mark certificate checks for BIMI logos: the VMC or CMC a company names
// in its BIMI record (a=) must chain to a mark certificate root, be a mark
// certificate (its extended key usage), be for the sender's domain, and
// carry the logo itself (RFC 3709), whose hash must match. Pure checks
// only, no network, so they can be tested on their own.
//
// What is checked: the chain up to one of the pinned roots below (each
// signature, each certificate's dates, CA flags, and the mark certificate
// usage on every certificate that names a usage), the domain in the
// leaf's subject alternative names, the embedded logo's hash, and the
// sender's DMARC policy (quarantine or reject), which BIMI requires.
// What is not: revocation (OCSP or CRL) and Certificate Transparency
// proofs. The mark drawn is the one inside the certificate, so a company
// can't show a logo its certificate doesn't carry.
const crypto = require('crypto');
const zlib = require('zlib');

const MARK_EKU = '1.3.6.1.5.5.7.3.31';
const LOGOTYPE_OID = '1.3.6.1.5.5.7.1.12';
const MAX_CERTIFICATES = 8;
const MAX_SVG = 64 * 1024;

// The roots mark certificates chain to. Each was downloaded from its CA's
// own server (the caIssuers address in the intermediates real VMCs carry)
// and matched the root bundled in live VMCs from several companies.
const ROOTS = [
  // DigiCert Verified Mark Root CA (VMCs and CMCs), valid to 2049.
  // http://cacerts.digicert.com/DigiCertVerifiedMarkRootCA.crt
  // SHA-256 50:43:86:C9:EE:89:32:FE:CC:95:FA:DE:42:7F:69:C3:E2:53:4B:73:10:48:9E:30:0F:EE:44:8E:33:C4:6B:42
  `-----BEGIN CERTIFICATE-----
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
0wberd/tg3N0dJsSSznZjwYB
-----END CERTIFICATE-----`,
  // GlobalSign Verified Mark Root R42, valid to 2042.
  // http://secure.globalsign.com/cacert/gsverifiedmarkrootr42.crt
  // SHA-256 CD:12:2C:B8:77:C6:92:8B:90:17:B0:F0:B8:0D:BD:50:81:96:30:0B:BD:03:CD:73:56:C3:BE:EF:52:4E:7E:0B
  `-----BEGIN CERTIFICATE-----
MIIFdDCCA1ygAwIBAgIQf+UwA4GYp199F8APJCyr8zANBgkqhkiG9w0BAQwFADBU
MQswCQYDVQQGEwJCRTEZMBcGA1UEChMQR2xvYmFsU2lnbiBudi1zYTEqMCgGA1UE
AxMhR2xvYmFsU2lnbiBWZXJpZmllZCBNYXJrIFJvb3QgUjQyMB4XDTIzMTExNTAz
NDA1MloXDTQyMTExNTAwMDAwMFowVDELMAkGA1UEBhMCQkUxGTAXBgNVBAoTEEds
b2JhbFNpZ24gbnYtc2ExKjAoBgNVBAMTIUdsb2JhbFNpZ24gVmVyaWZpZWQgTWFy
ayBSb290IFI0MjCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBANzqTcvu
bRbqX0CzP7sZbHfd1usqWOPrHzoLvbZTnJqt9WgBwQwcGEFl8rmIcOss7XmewAqj
oCx7PQp1FJ+/o/yGezMbnPCglAVwWptUOMIa7UJ/8qrV50/qQSRN8s8MAcnhj3Ab
Ja/mVjlMHzjYCo0O+jc24uHlEHcIo3vJPsP2Sy9HwcMH4wB2rQ4xDN7kAn5NmqXI
xAvSnJ2KGrZsoNx8MGAfX5dl0ACOpaaqbonBGtawvRGAE6f747E+pUamjGjisQ8y
ZC0X5Ht1s53sliy9AHDpOUWVcCLOoQCP/Y8yDjkjE1VWiL1Y7LlCnYfAVfY87DRD
81toIOLjFNACxeG02Qvgzg0JMKh81seiZfSLbq8DgepDABUTs8WYpN/u52/kdM+/
UeaQEn+q2HDDI8OMmBqwVo98k+dCQ0QgKLkHaLxpm5EjacSkNZFeqp1ttDZsGKQt
9REPJxpY6OO9KSYuFNFpnmLfaDNA/VngLw+Z4hYH59RnE2p3s95CfUa+CT4BUvDy
Wefc9RNiJVppbQNiZ4DKKpixVfXptgukbnh5l7vyDVonKGdgNEZeN5YjopM5V2+J
eIrsC3u0OmDV41cSFfe/1dmoUhy5EfTgWXqLOOgoUxqy62Yl7DDwoyXerEzDzZAq
nSBE/HAra3/d5pdj8/5WXoybjbXYM/bsKALLAgMBAAGjQjBAMA4GA1UdDwEB/wQE
AwIBhjAPBgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBQ9s+P1IK6506ybFLxwJe4P
Cn6VyTANBgkqhkiG9w0BAQwFAAOCAgEA24nHkncSyqeuk1lkpRq/MLVHdVONJnZ6
t8OZEu3nr6DHAuImAonIqO8HcBcgwydDIAeD7GOafOZ47mRkYOFIa+tkJ21pfmJv
KUt3ASW1uLAHCJNYHVLXs7txnq1mRKuwyuaeb6JdTazzjXgNDLZQgvOfM7mkDf6f
S2Z+dbKOZBYwo6zspqoQc1s6k0Xg9h7oEiJCC+3FUfJQSYyi2bynZSEn2c67OSFT
fqXVr9nhlaawLGEKUaFlYeQspUO5MUFYmGWqnf38M8ZM0rPx5R00jZ/E5sKcSqFH
CaVghDPiVv9Jzs8gNllwDbi7rXwMstaKATJJXiWgSdsxrfQr7+FRyXQJmRVXKxZ6
6uNe1ZgAzgNbjCvGmwF1StBtr1DrdOSk7sOMBMuJftB2g9/K67VUfz+jkylIbv5y
bvnCqBoAvq2DSQ76O5WyWiTBkPYp2Fh/WMHkXVIQpT6Q7FMTiGxtAxv69sq1CeJ9
i9g/iAJBdToQwJwH80Ah3hSPg1DQ8LTIjTtOxxkJ6Aeh/XU1/w9lW91XGLgXye1U
fjUIWKsoe1rE2RK+RSP6BZWcRNhJOyqi40gdTRLJkbc0Itq/62NFV4mIWcWKafhb
4ZOU1rvk1woeteJJZHd7cLakW6ONJAEtWGe43ZVx/lqFXQH4kOMPuR/7h2G1Aie6
Fk6hsIjUv20=
-----END CERTIFICATE-----`,
  // SSL.com VMC RSA Root CA 2024, valid to 2048. Also the root of
  // Sectigo's VMCs ("Sectigo Limited VMC Issuing RSA CA 1"), which now
  // include the ones Entrust used to issue.
  // http://cert.ssl.com/SSL.com-VMC-Root-2024-RSA.cer
  // SHA-256 8F:9D:1B:76:98:88:67:82:A5:99:B4:85:10:65:1C:66:A1:AA:0C:5C:A3:19:20:97:BD:C6:85:34:15:4B:D3:0D
  `-----BEGIN CERTIFICATE-----
MIIFiTCCA3GgAwIBAgIQcJRvrr6zzODYb7h2d4BhyzANBgkqhkiG9w0BAQsFADBO
MQswCQYDVQQGEwJVUzEYMBYGA1UECgwPU1NMIENvcnBvcmF0aW9uMSUwIwYDVQQD
DBxTU0wuY29tIFZNQyBSU0EgUm9vdCBDQSAyMDI0MB4XDTI0MDIxOTE2MjU1MVoX
DTQ4MDIxMzE2MjU1MFowTjELMAkGA1UEBhMCVVMxGDAWBgNVBAoMD1NTTCBDb3Jw
b3JhdGlvbjElMCMGA1UEAwwcU1NMLmNvbSBWTUMgUlNBIFJvb3QgQ0EgMjAyNDCC
AiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAIyEglUdOfMiwwS13+Q9dho5
swa3HbdPZByWNPwgD1tDdPYyCdox2F0bJxfrBnUFKCf46SZV7DESkn/YTKj7tMSk
Vr4c9GzNbr7WWSMprVEsgDrwDw/RM9YcwsFNlx1PFt+gDQhitA/ezIRO0uextBp4
0/HP7HQ7ZeOKVB0W71WoBty6TBCN+l5LVQGGDSvRGmQndf9zsmITQpddp1xAbUMA
uxFnkS22vYCHdEWzSVuEWLakVh53qcYF7krDZY82kIurOC1wEwGNkdsfQ0HLpf8Y
VhHMOm/JoCOXcA79nvjehykZb+7c1zgPgUjRd4d/UbwoDBy0Y4GrGw4Q+c0bscz/
xlrxf+SYIozASUEFjNcfvOkPCLlTHj7V8yhQRm58Q36/GdnahwLgdRwhk4WP5p7W
tkxJrHIvdsQJgIH9OVL089MHfOHQHuAcxV54+/YKr/AT6m3pgr+Zs067rQYMMc/k
TCGial39KMnkHydy8AduW+17U1auIpqt7XOtroC46IMbL2zVQDY1lyvUfvwc+5Kt
fjYVpnsle7g+fkEupWvbQHCWZR4iE9jFNR6ETF2damAMx+yuFP+dfyc4CAZUoGwz
0+ZhUIYuTeEMCPSuZAvHy0ugTPEuSc5LKnJ5JK+bOeqtbRkQVmFC74fkAqhkCfzt
vkckHbTCI5ukoeKueCRJAgMBAAGjYzBhMA8GA1UdEwEB/wQFMAMBAf8wHwYDVR0j
BBgwFoAUwTWi9FnZB3aX/croa3fWJq56WvswHQYDVR0OBBYEFME1ovRZ2Qd2l/3K
6Gt31iauelr7MA4GA1UdDwEB/wQEAwIBhjANBgkqhkiG9w0BAQsFAAOCAgEAIet3
+K2+sef6SZBE+5cFsnKYtagi50I1iECJQziusyw1wK9Keman4TZshwio4Z/nvaq2
ed3s3YYFL6BGksJTJPImrEaQI3aqHa16AEzw6F2k3gz78wbcpjygGJMekVrhyF5l
E+ErRcY9JGo1IGscBYlZcXkHJThNO9gEyoH+os73KIsY4120CBe3jbfOhRpDZioF
wUxepdzEzx8ZRXGsz58m+0NS0cBcvkqpIpnI2TFDT/lK0s2ys65h2YLhDsUnhtJ2
Kd8boP+ImazgpfpjgVEeCCpoPzWmmlMzxr083f0Mya4uSPidk/FkVYo3l+NAUcfH
WcfH6ca7Xrm5DXsOaP0cDWaYphbEKVVi164V03fNClW3p7xzLCDUfzdAaQs1JY1G
h0GgH4dNdp+BgGjjUPZ86IZhCuOq0rm3czfxb25l6WuAf7A0gq4oVgMNbbIepap8
YRbbU3nGl4A+s6qjtIhy6QGVWYqwQVElP7ba1sbhqLu5Uu/QyI/B5uEBO3oTvNgc
pld8jFKTqIO9yFgzvIO6XhfwW5VvLHozlzb7fM8hPKnrdd5HT3XnFTkKl/y4zLrw
OnvNhh5QMQe+HEnpScufX/cFPh568bVicV061IvLoGr84rlgxO+RjWuILOiXCVi0
7JsQLmpgD+ebpTit7HrVpCJa1SZXeHlzkc/yI74=
-----END CERTIFICATE-----`,
  // SSL.com VMC ECC Root CA 2024, valid to 2048.
  // http://cert.ssl.com/SSL.com-VMC-Root-2024-ECC.cer
  // SHA-256 1B:82:E7:F4:91:0B:51:E3:E8:02:A4:93:AC:DC:17:FF:58:EA:C8:B9:EB:7C:09:B5:2A:C6:CD:2E:FB:83:59:8C
  `-----BEGIN CERTIFICATE-----
MIICOjCCAcCgAwIBAgIQEUfBai0/SvdnXWXlwaytjjAKBggqhkjOPQQDAzBOMQsw
CQYDVQQGEwJVUzEYMBYGA1UECgwPU1NMIENvcnBvcmF0aW9uMSUwIwYDVQQDDBxT
U0wuY29tIFZNQyBFQ0MgUm9vdCBDQSAyMDI0MB4XDTI0MDIxOTE2MjUzMFoXDTQ4
MDIxMzE2MjUyOVowTjELMAkGA1UEBhMCVVMxGDAWBgNVBAoMD1NTTCBDb3Jwb3Jh
dGlvbjElMCMGA1UEAwwcU1NMLmNvbSBWTUMgRUNDIFJvb3QgQ0EgMjAyNDB2MBAG
ByqGSM49AgEGBSuBBAAiA2IABAlYNKIok2H2MoERpO66/tfLns/aRbbVN8HhNGbe
znXOJhQozKiHoCOCN7bCCuMdpAXVosUptXs+8Sksd8Hluh91J1W1QQVi9KyFSwgM
VTAynuA64X9MbrQNwkZaCQXPtKNjMGEwDwYDVR0TAQH/BAUwAwEB/zAfBgNVHSME
GDAWgBQl8MYq5N4ipgAt8VK4J42gUeKgpTAdBgNVHQ4EFgQUJfDGKuTeIqYALfFS
uCeNoFHioKUwDgYDVR0PAQH/BAQDAgGGMAoGCCqGSM49BAMDA2gAMGUCMHkYwAy0
rQ/BXQCanvUeTylOOCbaIO+rbFxOY8KF+AHmv0MJI7t++BnWUE1XwYABXAIxAKbi
1Mpz6UpoC5yWsed9Z1rhT+pMwzPwNrdsRMLAesSq2Jbv0UGQ/1uJcM/6OtDFgQ==
-----END CERTIFICATE-----`,
].map((pem) => new crypto.X509Certificate(pem));

class MarkError extends Error {
  constructor(reason) {
    super(reason);
    this.reason = reason;
  }
}

// ---- A minimal DER reader ------------------------------------------------

function readTLV(buf, offset, end = buf.length) {
  if (offset + 2 > end) throw new MarkError('bad-certificate');
  const tag = buf[offset];
  let length = buf[offset + 1];
  let start = offset + 2;
  if (length & 0x80) {
    const count = length & 0x7f;
    if (count < 1 || count > 4 || start + count > end) throw new MarkError('bad-certificate');
    length = 0;
    for (let i = 0; i < count; i++) length = length * 256 + buf[start + i];
    start += count;
  }
  if (start + length > end) throw new MarkError('bad-certificate');
  return { tag, start, end: start + length };
}

function children(buf, tlv) {
  const out = [];
  let offset = tlv.start;
  while (offset < tlv.end) {
    const child = readTLV(buf, offset, tlv.end);
    out.push(child);
    offset = child.end;
  }
  return out;
}

function oidString(buf, tlv) {
  const der = buf.subarray(tlv.start, tlv.end);
  if (der.length === 0) return '';
  const parts = [Math.floor(der[0] / 40), der[0] % 40];
  let value = 0;
  for (let i = 1; i < der.length; i++) {
    value = value * 128 + (der[i] & 0x7f);
    if (!(der[i] & 0x80)) { parts.push(value); value = 0; }
  }
  return parts.join('.');
}

// The raw value of one extension, or null.
function extension(cert, oid) {
  const der = cert.raw;
  const certificate = readTLV(der, 0);
  const tbs = children(der, certificate)[0];
  const extensions = children(der, tbs).find((c) => c.tag === 0xa3);
  if (!extensions) return null;
  for (const ext of children(der, children(der, extensions)[0])) {
    const parts = children(der, ext);
    if (parts[0].tag === 0x06 && oidString(der, parts[0]) === oid) {
      const value = parts[parts.length - 1];
      if (value.tag !== 0x04) throw new MarkError('bad-certificate');
      return der.subarray(value.start, value.end);
    }
  }
  return null;
}

// ---- The logo inside the certificate (RFC 3709) ---------------------------

const HASHES = {
  '1.3.14.3.2.26': 'sha1',
  '2.16.840.1.101.3.4.2.1': 'sha256',
  '2.16.840.1.101.3.4.2.2': 'sha384',
  '2.16.840.1.101.3.4.2.3': 'sha512',
};

// Every LogotypeDetails in the extension: { mediaType IA5String,
// logotypeHash SEQUENCE OF HashAlgAndValue, logotypeURI SEQUENCE OF
// IA5String }, found wherever it sits (subject, community or other logos).
function logotypeDetails(buf, tlv, found = [], depth = 0) {
  if (depth > 12) return found;
  const parts = children(buf, tlv);
  if (parts.length === 3 && parts[0].tag === 0x16 && parts[1].tag === 0x30 && parts[2].tag === 0x30) {
    const mediaType = buf.subarray(parts[0].start, parts[0].end).toString('latin1');
    const hashes = [];
    for (const item of children(buf, parts[1])) {
      const [alg, value] = children(buf, item);
      if (!alg || !value || alg.tag !== 0x30 || value.tag !== 0x04) continue;
      const oid = children(buf, alg)[0];
      if (!oid || oid.tag !== 0x06) continue;
      hashes.push({ algorithm: HASHES[oidString(buf, oid)] || null, value: buf.subarray(value.start, value.end) });
    }
    const uris = children(buf, parts[2]).filter((u) => u.tag === 0x16)
      .map((u) => buf.subarray(u.start, u.end).toString('latin1'));
    found.push({ mediaType, hashes, uris });
    return found;
  }
  for (const part of parts) {
    // Constructed values only (SEQUENCE and the context tags around them).
    if (part.tag & 0x20) logotypeDetails(buf, part, found, depth + 1);
  }
  return found;
}

function dataURIBytes(uri) {
  const match = /^data:([^,]*),(.*)$/s.exec(uri);
  if (!match) return null;
  if (/;base64$/i.test(match[1])) return Buffer.from(match[2], 'base64');
  try { return Buffer.from(decodeURIComponent(match[2]), 'latin1'); } catch { return null; }
}

// The SVG the certificate carries, after its hash checks out.
function embeddedSVG(cert) {
  const value = extension(cert, LOGOTYPE_OID);
  if (!value) throw new MarkError('no-logo');
  for (const details of logotypeDetails(value, readTLV(value, 0))) {
    if (!/^image\/svg\+xml$/i.test(details.mediaType)) continue;
    const known = details.hashes.filter((h) => h.algorithm);
    if (known.length === 0) continue;
    for (const uri of details.uris) {
      const bytes = dataURIBytes(uri);
      if (!bytes) continue;
      let svg = bytes;
      if (svg[0] === 0x1f && svg[1] === 0x8b) {
        try { svg = zlib.gunzipSync(svg, { maxOutputLength: MAX_SVG }); } catch { throw new MarkError('logo-size'); }
      }
      if (svg.length > MAX_SVG) throw new MarkError('logo-size');
      // The issuers seen so far hash the SVG itself (the same file as the
      // record's l=); the compressed bytes are accepted too.
      const hashed = (data) => known.every((h) => crypto.createHash(h.algorithm).update(data).digest().equals(h.value));
      if (!hashed(svg) && !hashed(bytes)) throw new MarkError('logo-hash');
      return svg.toString('utf8');
    }
  }
  throw new MarkError('no-logo');
}

// ---- The chain -------------------------------------------------------------

function certificatesIn(pemText) {
  const blocks = String(pemText).match(/-----BEGIN CERTIFICATE-----[A-Za-z0-9+/=\s]+?-----END CERTIFICATE-----/g) || [];
  if (blocks.length === 0) throw new MarkError('no-certificate');
  if (blocks.length > MAX_CERTIFICATES) throw new MarkError('too-many-certificates');
  try {
    return blocks.map((block) => new crypto.X509Certificate(block));
  } catch {
    throw new MarkError('bad-certificate');
  }
}

function inDate(cert, now) {
  return new Date(cert.validFrom).getTime() <= now && now <= new Date(cert.validTo).getTime();
}

// A usage list, when a certificate has one, must allow mark certificates.
function allowsMarks(cert) {
  const usages = cert.keyUsage;
  return !usages || usages.length === 0 || usages.includes(MARK_EKU);
}

function issuedBy(cert, issuer) {
  try {
    return issuer.ca && cert.checkIssued(issuer) && cert.verify(issuer.publicKey);
  } catch {
    return false;
  }
}

// The leaf (the one certificate that isn't a CA; BIMI puts it first),
// once it chains to a pinned root through the certificates that came with it.
function verifyChain(certs, { roots = ROOTS, now = Date.now() } = {}) {
  const leaf = certs.find((c) => !c.ca) || certs[0];
  if (leaf.ca) throw new MarkError('leaf-is-ca');
  if (!(leaf.keyUsage || []).includes(MARK_EKU)) throw new MarkError('not-a-mark-certificate');
  if (!inDate(leaf, now)) throw new MarkError('expired');
  let current = leaf;
  const used = new Set([leaf]);
  for (let depth = 0; depth < MAX_CERTIFICATES; depth++) {
    const root = roots.find((r) => issuedBy(current, r));
    if (root) {
      if (!inDate(root, now)) throw new MarkError('expired');
      return leaf;
    }
    const next = certs.find((c) => !used.has(c) && issuedBy(current, c));
    if (!next) throw new MarkError('untrusted');
    // A bundled copy of a pinned root is fine; any other self-signed one is not.
    if (next.checkIssued(next)) throw new MarkError('untrusted');
    if (!inDate(next, now)) throw new MarkError('expired');
    if (!allowsMarks(next)) throw new MarkError('not-a-mark-certificate');
    used.add(next);
    current = next;
  }
  throw new MarkError('untrusted');
}

function dnsNames(cert) {
  const names = [];
  for (const part of String(cert.subjectAltName || '').split(/,\s*/)) {
    const match = /^DNS:"?([^"]+)"?$/.exec(part.trim());
    if (match) names.push(match[1].toLowerCase().replace(/\.$/, ''));
  }
  return names;
}

// Whether the certificate names one of these domains, directly or as
// "<selector>._bimi.<domain>". No wildcards.
function namesDomain(cert, domains) {
  const wanted = new Set(domains.map((d) => d.toLowerCase()));
  return dnsNames(cert).some((name) => {
    if (wanted.has(name)) return true;
    const at = name.indexOf('._bimi.');
    return at > 0 && !name.slice(0, at).includes('.') && wanted.has(name.slice(at + 7));
  });
}

// The mark to draw: the SVG inside a valid mark certificate for one of
// `domains`. Throws a MarkError saying why not.
function verifiedMark(pemText, domains, options = {}) {
  const certs = certificatesIn(pemText);
  const leaf = verifyChain(certs, options);
  if (!namesDomain(leaf, domains)) throw new MarkError('wrong-domain');
  return embeddedSVG(leaf);
}

// ---- DMARC -----------------------------------------------------------------

function parseDMARC(record) {
  const text = String(record || '').trim();
  if (!/^v\s*=\s*DMARC1\s*(;|$)/i.test(text)) return null;
  const tags = {};
  for (const part of text.split(';')) {
    const at = part.indexOf('=');
    if (at > 0) tags[part.slice(0, at).trim().toLowerCase()] = part.slice(at + 1).trim().toLowerCase();
  }
  return tags;
}

const ENFORCED = new Set(['quarantine', 'reject']);

// BIMI asks for an enforced DMARC policy: the organizational domain's own
// policy quarantine or reject at 100%, and for a subdomain, its own record
// (or else the organizational sp=) enforced too.
function dmarcEnforced(domainRecord, orgRecord, isSubdomain) {
  const org = parseDMARC(orgRecord);
  if (!org || !ENFORCED.has(org.p) || (org.pct && org.pct !== '100')) return false;
  if (!isSubdomain) return true;
  const own = parseDMARC(domainRecord);
  if (own) return ENFORCED.has(own.p) && (!own.pct || own.pct === '100');
  return !org.sp || ENFORCED.has(org.sp);
}

module.exports = {
  verifiedMark, verifyChain, certificatesIn, namesDomain, embeddedSVG, parseDMARC, dmarcEnforced,
  MarkError, ROOTS, MARK_EKU,
};
